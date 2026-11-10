#!/usr/bin/env python3
"""Build source-only guest adapter and host compiler helper; never install/start them."""
import argparse,hashlib,json,os,shlex,subprocess,sys,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'compiler'))
from recipe import prepare
from toolchain import llvm_config

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'build');p.add_argument('--native-test',action='store_true');a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True);os.environ['HENGE_DYNAMIC_BUILD']=str(out);recipe=prepare(a.native_test);commands=[]
 def run(cmd):
  q=subprocess.run(cmd,capture_output=True,text=True,timeout=90);commands.append(dict(command=cmd,returncode=q.returncode,stdout=q.stdout,stderr=q.stderr));(out/'build-commands.json').write_text(json.dumps(commands,indent=2)+'\n');q.check_returncode()
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip();flags=shlex.split(subprocess.check_output([llvm_config(),'--cxxflags','--ldflags','--libs','core','bitreader','bitwriter','irreader','transformutils','--system-libs'],text=True));run(['xcrun','clang++',str(ROOT/'compiler/close_air.cpp'),*flags,'-std=c++20','-isysroot',sdk,'-o',str(out/'close-air')])
 guest=out/'guest';guest.mkdir(exist_ok=True);cmd=['xcrun','clang','-dynamiclib','-arch','arm64','-mmacosx-version-min=14.0','-fobjc-arc','-fblocks','-DHG_RECIPE_ID="'+recipe+'"',str(ROOT/'guest/runtime.m'),'-framework','Foundation','-framework','Metal','-install_name','@rpath/libHengeDynamic.dylib','-o',str(guest/'libHengeDynamic.dylib')]
 if a.native_test:cmd.insert(2,'-DHG_ALLOW_NATIVE_TESTING=1')
 run(cmd)
 for name in ['run.sh','install.sh','uninstall.sh']:
  target=guest/name;target.write_bytes((ROOT/'guest'/name).read_bytes());target.chmod(0o755)
 (guest/'recipe.json').write_bytes((out/'recipe.json').read_bytes());(guest/'libHengeDynamic.dylib').chmod(0o755)
 manifest={'schema':1,'recipe_sha256':recipe,'native_test_build':a.native_test,'files':{p.name:{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'mode':oct(p.stat().st_mode&0o777)}for p in sorted(guest.iterdir()) if p.is_file() and p.name not in ('manifest.json','manifest.sha256')}}
 (guest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 (guest/'manifest.sha256').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.name+'\n' for f in sorted(guest.iterdir()) if f.is_file() and f.name!='manifest.sha256'))
 with tarfile.open(out/'henge-dynamic-guest.tar.gz','w:gz')as t:
  for f in sorted(guest.iterdir()):t.add(f,arcname=f.name)
 with tarfile.open(out/'henge-dynamic-guest.tar.gz')as t:
  for m in t.getmembers():
   if m.name.endswith(('.sh','.dylib')):assert m.mode&0o111,'non-executable package member: '+m.name
 print(json.dumps(dict(recipe=recipe,guest_archive=str(out/'henge-dynamic-guest.tar.gz'),sha256=hashlib.sha256((out/'henge-dynamic-guest.tar.gz').read_bytes()).hexdigest(),native_test=a.native_test)))
if __name__=='__main__':main()
