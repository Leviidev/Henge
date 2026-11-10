#!/usr/bin/env python3
"""Explicit TrollStore SSH update; never uninstalls an app or replaces guest disks.

Preflight and update require operator-selected SSH/container/machine identities.
All receipts and auxiliary backups are private local outputs, not source assets.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shlex
import shutil
import subprocess
import tempfile
import uuid
import zipfile

NORMALIZE_SOURCE = r'''
def normalized_macho(data):
    import struct,hashlib
    if len(data)<32:raise ValueError('Truncated Mach-O')
    magic,cpu,sub,filetype,ncmd,sizecmd=struct.unpack_from('<6I',data)
    if magic!=0xfeedfacf or cpu!=0x100000c:raise ValueError('Thin arm64 Mach-O required')
    end=32+sizecmd
    if end>len(data):raise ValueError('Bad load command bounds')
    normalized=bytearray(data);at=32;signature=None
    for _ in range(ncmd):
        cmd,size=struct.unpack_from('<2I',data,at)
        if size<8 or at+size>end:raise ValueError('Bad load command')
        if cmd==0x1d:
            if size<16:raise ValueError('Bad signature command')
            offset,length=struct.unpack_from('<2I',data,at+8)
            if offset<end or offset+length>len(data):raise ValueError('Bad signature bounds')
            signature=offset;normalized[at+8:at+16]=b'\x00'*8
        if cmd==0x19 and data[at+8:at+24].rstrip(b'\x00')==b'__LINKEDIT':
            if size<72:raise ValueError('Bad LINKEDIT command')
            normalized[at+32:at+40]=b'\x00'*8;normalized[at+48:at+56]=b'\x00'*8
        at+=size
    if signature is None or at!=end:raise ValueError('Missing signature or malformed commands')
    return hashlib.sha256(normalized[:signature]).hexdigest()
'''
exec(NORMALIZE_SOURCE)

HALT = 'henge: the machine stopped (halt)'
REMOTE_STATE = NORMALIZE_SOURCE + r'''
from pathlib import Path
import ctypes, hashlib, json, plistlib
cfg=CONFIG
version=plistlib.loads(Path('/System/Library/CoreServices/SystemVersion.plist').read_bytes())
libc=ctypes.CDLL(None);length=ctypes.c_size_t(0)
assert libc.sysctlbyname(b'hw.machine',None,ctypes.byref(length),None,0)==0
buffer=ctypes.create_string_buffer(length.value)
assert libc.sysctlbyname(b'hw.machine',buffer,ctypes.byref(length),None,0)==0
model=buffer.value.decode()
assert version['ProductVersion']==cfg['expected_os'], 'OS does not match selected target'
assert version['ProductBuildVersion']==cfg['expected_os_build'], 'OS build does not match selected target'
assert Path(cfg['app_control']).is_file(), 'Configured icli-compatible app controller is missing'
assert model==cfg['expected_model'], 'Hardware model does not match selected target'
data=Path(cfg['data_container']).resolve();machine=Path(cfg['machine_directory']).resolve()
assert (data/'Documents').is_dir() and (data/'Library/Application Support/Machines') in machine.parents
metadata=plistlib.loads((data/'.com.apple.mobile_container_manager.metadata.plist').read_bytes())
assert metadata['MCMMetadataIdentifier']==cfg['bundle_id'], 'Data container belongs to another app'
apps=[];helpers=[]
for path in Path('/var/containers/Bundle/Application').glob('*/*.app/Info.plist'):
    try:info=plistlib.loads(path.read_bytes())
    except Exception:continue
    if info.get('CFBundleIdentifier')==cfg['bundle_id']:apps.append((path.parent,info))
    if path.parent.name=='TrollStore.app' and (path.parent/'trollstorehelper').is_file():helpers.append(path.parent/'trollstorehelper')
assert len(apps)==1 and len(helpers)==1, 'Ambiguous/missing app or TrollStore helper'
app,info=apps[0];executable=app/info['CFBundleExecutable']
assert executable.parent==app and executable.is_file()
log=(data/'Documents/henge.log').read_bytes()
assert log.rstrip().endswith(b'henge: the machine stopped (halt)'), 'Guest must halt normally before update'
files={}
for name in ['disk.img','auxiliary.bin']:
    path=machine/name;s=path.stat()
    assert path.is_file() and not path.is_symlink()
    files[name]={'device':s.st_dev,'inode':s.st_ino,'size':s.st_size,'mtime_ns':s.st_mtime_ns}
    if name=='auxiliary.bin':files[name]['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
print(json.dumps({'model':model,'os':version['ProductVersion'],'os_build':version['ProductBuildVersion'],
 'bundle_id':cfg['bundle_id'],'app':str(app),'executable_sha256':hashlib.sha256(executable.read_bytes()).hexdigest(),
 'normalized_executable_sha256':normalized_macho(executable.read_bytes()),'data_container':str(data),'machine_directory':str(machine),'storage':files,'trollstore_helper':str(helpers[0]),'trollstore_helper_sha256':hashlib.sha256(helpers[0].read_bytes()).hexdigest(),
 'halt_log_sha256':hashlib.sha256(log).hexdigest()}))
'''


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for b in iter(lambda:stream.read(1024*1024),b''):h.update(b)
    return h.hexdigest()


def package_identity(path):
    """Inspect without extracting; reject ambiguous bundles and unsafe archive paths."""
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            p=PurePosixPath(name)
            if p.is_absolute() or '..'in p.parts:raise ValueError('Unsafe package member')
        infos=[n for n in z.namelist()if len(PurePosixPath(n).parts)==3 and n.startswith('Payload/')and n.endswith('.app/Info.plist')]
        if len(infos)!=1:raise ValueError('Exactly one top-level application is required')
        info=plistlib.loads(z.read(infos[0]));bundle=info['CFBundleIdentifier'];exe=info['CFBundleExecutable']
        if not isinstance(bundle,str)or not isinstance(exe,str)or '/'in exe or exe in ['.','..']:raise ValueError('Invalid app identity')
        executable=str(PurePosixPath(infos[0]).parent/exe)
        return {'sha256':digest(path),'bundle_id':bundle,'executable_sha256':hashlib.sha256(z.read(executable)).hexdigest(),'normalized_executable_sha256':normalized_macho(z.read(executable)),'bytes':Path(path).stat().st_size}


class Remote:
    def __init__(self,config):
        host=config['host']
        if host.startswith('-')or any(c.isspace()for c in host):raise ValueError('Use a configured SSH host or user@host')
        self.args=['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15']
        if config.get('host_key_alias'):self.args+=['-o','HostKeyAlias='+config['host_key_alias']]
        self.args+=[host]
    def code(self,code,stdin=None,timeout=120):
        p=subprocess.run(self.args+['python3 -c '+shlex.quote(code)],input=stdin,capture_output=True,timeout=timeout)
        if p.returncode:raise RuntimeError(p.stderr.decode(errors='replace')[-8000:])
        return p.stdout
    def state(self,config):return json.loads(self.code(REMOTE_STATE.replace('CONFIG',repr(config))))
    def read(self,path):return self.code('from pathlib import Path;import sys;sys.stdout.buffer.write(Path('+repr(path)+').read_bytes())')
    def upload(self,path,remote_path,expected):
        code='import sys,hashlib;from pathlib import Path;p=Path('+repr(remote_path)+');data=sys.stdin.buffer.read();assert hashlib.sha256(data).hexdigest()=='+repr(expected)+';p.write_bytes(data);p.chmod(0o600)'
        self.code(code,Path(path).read_bytes())
    def install(self,state,config,remote_path,expected):
        # Match the tested ordering: guest halt checked, app killed, helper install.
        # No uninstall command exists here. Recheck both halt and storage before kill.
        code=REMOTE_STATE.replace('CONFIG',repr(config))
        code=code[:code.index('print(json.dumps(')]
        code+='\nassert files=='+repr(state['storage'])+'\n'
        code+='assert normalized_macho(executable.read_bytes())=='+repr(state['normalized_executable_sha256'])+'\n'
        code+='\nimport subprocess\np=Path('+repr(remote_path)+');assert hashlib.sha256(p.read_bytes()).hexdigest()=='+repr(expected)+'\n'
        code+="kill=subprocess.run([cfg['app_control'],'app','kill','--force',cfg['bundle_id']],capture_output=True,text=True);assert kill.returncode==0,kill.stderr\n"
        code+="result=subprocess.run([str(helpers[0]),'install',str(p)],capture_output=True,text=True)\n"
        code+="print(json.dumps({'installer_exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr}))\n"
        return json.loads(self.code(code,timeout=180))


def save(path,value):path.write_text(json.dumps(value,indent=2)+'\n')


def new_private_directory(path):
    path.mkdir(parents=True,exist_ok=False,mode=0o700)
    os.chmod(path,0o700)


def update(plan,package,rollback,output,remote_factory=Remote):
    config=json.loads((plan/'target.json').read_text());before=json.loads((plan/'preflight.json').read_text())
    candidate=package_identity(package);previous=package_identity(rollback)
    if candidate['bundle_id']!=config['bundle_id']or previous['bundle_id']!=config['bundle_id']:raise ValueError('Candidate and rollback must use the selected installed bundle ID')
    remote=remote_factory(config);current=remote.state(config)
    if current!=before:raise ValueError('Preflight target changed; create a fresh plan')
    new_private_directory(output)
    save(output/'target.json',config);save(output/'before-storage.json',before)
    shutil.copyfile(package,output/'candidate.tipa');shutil.copyfile(rollback,output/'rollback.tipa')
    save(output/'packages.json',{'candidate':candidate,'rollback':previous,'rollback_note':'Operator supplies known-good IPA; signing may make its executable hash differ from the currently installed TrollStore executable.'})
    aux=remote.read(before['machine_directory']+'/auxiliary.bin')
    if hashlib.sha256(aux).hexdigest()!=before['storage']['auxiliary.bin']['sha256']:raise ValueError('Auxiliary changed during backup')
    (output/'auxiliary.before.bin').write_bytes(aux)
    if remote.state(config)!=before:raise ValueError('Target changed while backing up')
    remote_path='/var/mobile/Media/henge-update-'+uuid.uuid4().hex+'.tipa'
    remote.upload(output/'candidate.tipa',remote_path,candidate['sha256'])
    result=remote.install(before,config,remote_path,candidate['sha256']);save(output/'app-update.json',result)
    if result['installer_exit']!=0:raise RuntimeError('TrollStore failed; receipts preserved; no automatic data rollback')
    after=remote.state(config);save(output/'after-storage.json',after)
    if after['normalized_executable_sha256']!=candidate['normalized_executable_sha256']:raise RuntimeError('Installed executable does not match candidate code; stop and inspect app receipt')
    preserved=all(after[k]==before[k]for k in ['data_container','machine_directory','storage','bundle_id','model','os','os_build'])
    save(output/'data-preservation.json',{'unchanged':preserved,'disk_check':'device/inode/size/mtime identity; not a full disk content hash','auxiliary_check':'identity and SHA256','app_update_separate':True})
    if not preserved:raise RuntimeError('Storage identity changed; stop and inspect receipts. Guest data has not been restored or overwritten by this tool.')
    print('In-place app update completed; storage identity preserved. Perform visible/JIT/input/audio health checks before discarding rollback package.')


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__);commands=parser.add_subparsers(dest='command',required=True)
    p=commands.add_parser('preflight')
    for name in ['host','bundle-id','data-container','machine-directory','expected-os','expected-os-build','expected-model']:p.add_argument('--'+name,required=True)
    p.add_argument('--app-control',default='/var/jb/usr/bin/icli',help='Remote icli-compatible app-control executable');p.add_argument('--host-key-alias');p.add_argument('--output',type=Path,required=True)
    p=commands.add_parser('update');p.add_argument('--plan',type=Path,required=True);p.add_argument('--package',type=Path,required=True);p.add_argument('--rollback-package',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=parser.parse_args()
    if a.command=='preflight':
        config={k:v for k,v in vars(a).items()if k not in ['command','output']};state=Remote(config).state(config)
        new_private_directory(a.output);save(a.output/'target.json',config);save(a.output/'preflight.json',state);print('Preflight saved. Review target, storage identity and halted state before update.')
    else:update(a.plan,a.package,a.rollback_package,a.output)

if __name__=='__main__':main()
