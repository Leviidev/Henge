#!/usr/bin/env python3
"""Launch one selected macOS process with opt-in PV OpenGL renderer discovery.

Never writes to the app, registry, LaunchServices, login environment or signatures.
"""
import argparse,hashlib,json,os,plistlib,subprocess,sys
from pathlib import Path

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def executable(app):
 info=plistlib.loads((app/'Contents/Info.plist').read_bytes());name=info['CFBundleExecutable']
 if '/'in name or name in ('.','..'):raise ValueError('Invalid bundle executable')
 return app/'Contents/MacOS'/name,info

def restrictions(target):
 r=subprocess.run(['codesign','-dv','--verbose=4',str(target)],capture_output=True,text=True)
 detail=r.stderr
 e=subprocess.run(['codesign','-d','--entitlements',':-',str(target)],capture_output=True)
 try:ent=plistlib.loads(e.stdout)if e.stdout else{}
 except plistlib.InvalidFileException:ent={}
 if '(runtime)'in detail and not(ent.get('com.apple.security.cs.disable-library-validation')and ent.get('com.apple.security.cs.allow-dyld-environment-variables')):
  raise ValueError('Hardened runtime restricts DYLD injection/library validation for this app. Use a supported app build with both entitlements; this helper does not re-sign arbitrary apps.')
 return {'codesign_status':r.returncode,'details':detail,'entitlements':ent}

def main():
 p=argparse.ArgumentParser(description=__doc__);g=p.add_mutually_exclusive_group(required=True);g.add_argument('--app',type=Path);g.add_argument('--executable',type=Path)
 p.add_argument('--shim',type=Path,required=True);p.add_argument('--receipt',type=Path,required=True);p.add_argument('--log',type=Path,required=True);p.add_argument('--additional-dylib',type=Path,action='append',default=[]);p.add_argument('--dry-run',action='store_true');p.add_argument('args',nargs=argparse.REMAINDER);a=p.parse_args()
 if os.environ.get('DYLD_INSERT_LIBRARIES'):raise SystemExit('Inherited DYLD_INSERT_LIBRARIES refused; specify each additional library explicitly.')
 target,info=executable(a.app.resolve())if a.app else(a.executable.resolve(),{})
 if not target.is_file()or not os.access(target,os.X_OK):raise SystemExit('Target is not executable')
 libs=[a.shim.resolve()]+[x.resolve()for x in a.additional_dylib]
 if any(not x.is_file()or ':'in str(x)for x in libs):raise SystemExit('Every library must exist and have a colon-free path')
 if a.receipt.exists()or a.log.exists():raise SystemExit('Receipt and log paths must be new')
 signature=restrictions(target);env=os.environ.copy()
 # App-supplied LaunchServices variables normally apply only through `open`.
 # Preserve those values explicitly for this direct, fresh process.
 for key,value in info.get('LSEnvironment',{}).items():
  if key=='DYLD_INSERT_LIBRARIES':raise SystemExit('App embeds DYLD injection; review and provide an explicit supported app first')
  if isinstance(key,str)and isinstance(value,str):env[key]=value
 env['DYLD_INSERT_LIBRARIES']=':'.join(map(str,libs));env['HENGE_CGL_DISCOVERY_TEST']='1'
 # A prior Henge software-fallback flag contradicts accelerated discovery.
 env.pop('HENGE_CGL_SOFTWARE_FALLBACK',None)
 args=a.args[1:]if a.args[:1]==['--']else a.args;command=[str(target),*args]
 receipt={'schema':1,'command':command,'target_sha256':sha(target),'libraries':{str(x):sha(x)for x in libs},'signature':signature,'environment_overrides':{'DYLD_INSERT_LIBRARIES':env['DYLD_INSERT_LIBRARIES'],'HENGE_CGL_DISCOVERY_TEST':'1','HENGE_CGL_SOFTWARE_FALLBACK':None},'dry_run':a.dry_run,'scope':'Fresh direct process; no installed or global state changed; renderer success requires observed output.'}
 a.receipt.parent.mkdir(parents=True,exist_ok=True);a.receipt.write_text(json.dumps(receipt,indent=2)+'\n')
 if a.dry_run:return
 a.log.parent.mkdir(parents=True,exist_ok=True)
 with a.log.open('x')as log:r=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT)
 receipt['exit_code']=r.returncode;a.receipt.write_text(json.dumps(receipt,indent=2)+'\n');raise SystemExit(r.returncode)
if __name__=='__main__':main()
