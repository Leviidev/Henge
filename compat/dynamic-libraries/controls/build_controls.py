#!/usr/bin/env python3
"""Build only authored Metal fixtures; no captured or shipped libraries."""
from pathlib import Path
import argparse,subprocess,sys,json,hashlib,shutil,tarfile
ROOT=Path(__file__).resolve().parent;sys.path.insert(0,str(ROOT.parent/'compiler'))
from container_pack import pack

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True);assets=out/'AuditAssets';assets.mkdir(exist_ok=True);cmds=[]
 def run(cmd):
  q=subprocess.run(cmd,capture_output=True,text=True,timeout=60);cmds.append(dict(command=cmd,returncode=q.returncode,stderr=q.stderr));q.check_returncode()
 def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
 for name in ['alpha','beta','dynamic-source','dynamic-consumer']:
  run(['xcrun','--sdk','macosx','metal','-c',str(ROOT/(name+'.metal')),'-target','air64_v26-apple-macosx14.0.0','-o',str(out/(name+'.air'))])
 for name in ['alpha','beta']:run(['xcrun','--sdk','macosx','metallib',str(out/(name+'.air')),'-o',str(out/(name+'.metallib'))])
 packed=pack([out/'alpha.metallib',out/'beta.metallib']);(assets/'packed-control.metallib').write_bytes(packed[0] if isinstance(packed,tuple)else packed)
 for name,install in [('dynamic-control','@executable_path/AuditAssets/dynamic-control.metallib'),('dynamic-loader','@loader_path/dynamic-loader.metallib')]:run(['xcrun','--sdk','macosx','air-lld','--create-shared-library','--arch','air64','--macos_version_min','14.0','--install_name',install,str(out/'dynamic-source.air'),'-o',str(assets/(name+'.metallib'))])
 run(['xcrun','--sdk','macosx','air-lld','--arch','air64','--macos_version_min','14.0',str(out/'dynamic-consumer.air'),str(assets/'dynamic-loader.metallib'),'-o',str(assets/'consumer-loader.metallib')])
 for n in ['dynamic-source.metal','dynamic-consumer.metal']:shutil.copyfile(ROOT/n,assets/n)
 common=dict(consumer_source_file='dynamic-consumer.metal',consumer_source_sha256=sha(assets/'dynamic-consumer.metal'))
 cases=[]
 for ident,kind in [('relative_source_baseline','relative_source'),('loader_file_consumer','loader_file'),('absolute_serialized_source_consumer','absolute_source'),('undefined_allowed_preloaded_only','preloaded_only')]:
  row=dict(common,id=ident,kind=kind,gate='expected_rejection'if kind=='relative_source'else'256_exact')
  if kind=='absolute_source':row.update(shared_source_file='dynamic-source.metal',shared_source_sha256=sha(assets/'dynamic-source.metal'))
  else:
   f='dynamic-loader.metallib'if kind=='loader_file'else'dynamic-control.metallib';row.update(shared_file=f,shared_sha256=sha(assets/f))
  if kind=='loader_file':row.update(consumer_library_file='consumer-loader.metallib',consumer_library_sha256=sha(assets/'consumer-loader.metallib'))
  cases.append(row)
 manifest=dict(schema=1,allowed_stages=['controls'],jobs=[],controls=dict(packed=dict(file='packed-control.metallib',sha256=sha(assets/'packed-control.metallib')),dynamic=dict(cases=cases)),asset_sha256={f.name:sha(f)for f in assets.iterdir()if f.is_file()})
 (assets/'inventory-jobs.json').write_text(json.dumps(manifest,indent=2)+'\n')
 for source,name in [('path_runner.m','dynamic-controls'),('async_lifetime.m','async-lifetime'),('dependency_snapshot.m','dependency-snapshot')]:
  run(['xcrun','clang','-arch','arm64','-mmacosx-version-min=14.0','-fobjc-arc','-fblocks',str(ROOT/source),'-framework','Foundation','-framework','AppKit','-framework','Metal','-o',str(out/name)]);(out/name).chmod(0o755)
 (out/'build-commands.json').write_text(json.dumps(cmds,indent=2)+'\n')
 with tarfile.open(out/'authored-controls.tar.gz','w:gz')as t:
  for f in [out/'dynamic-controls',out/'async-lifetime',out/'dependency-snapshot',*sorted(assets.rglob('*'))]:
   if f.is_file():t.add(f,arcname=f.relative_to(out))
 with tarfile.open(out/'authored-controls.tar.gz')as t:
  for n in ['dynamic-controls','async-lifetime','dependency-snapshot']:assert t.getmember(n).mode&0o111
 print(out/'authored-controls.tar.gz')
if __name__=='__main__':main()
