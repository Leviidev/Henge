#!/usr/bin/env python3
"""Build the pinned source-only provider in a new isolated directory, then stage its library."""
import argparse,hashlib,json,shutil,subprocess,os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--llvm-source',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--jobs',type=int,default=4)
a=p.parse_args();source=ROOT/'compat/ondevice-shaders';out=a.output.resolve()
dynamic=ROOT/'compat/ondevice-dynamic'
def source_hashes():
 ordinary={x.name:hashlib.sha256(x.read_bytes()).hexdigest()for x in source.iterdir()if x.is_file() and x.name not in ['README.md','.gitignore']}
 linked={'dynamic/'+n:hashlib.sha256((dynamic/n).read_bytes()).hexdigest()for n in ('stateless_link.cpp','HGStatelessLink.h')}
 guest={'guest/'+n:hashlib.sha256((ROOT/'compat/dynamic-libraries/guest'/n).read_bytes()).hexdigest()for n in ('adapter.m','transport.m','runtime.m')}
 return {**ordinary,**linked,**guest}
inputs=source_hashes()
if out.exists():raise SystemExit('Choose a new output directory; existing builds are preserved')
for name in ['HGOnDeviceShaderProvider.h','pvg_shader_profile.h','HGOnDeviceDynamicService.h']:
 if (source/name).read_bytes()!=(ROOT/'devices'/name).read_bytes():raise SystemExit('Provider/API contract differs: '+name)
out.mkdir(parents=True)
for item in source.iterdir():
 if item.is_file() and item.name not in ['README.md','.gitignore']:shutil.copy2(item,out/item.name)
(out/'dynamic').mkdir()
for name in ('stateless_link.cpp','HGStatelessLink.h'):shutil.copy2(dynamic/name,out/'dynamic'/name)
(out/'guest').mkdir()
for name in ('adapter.m','transport.m','runtime.m'):shutil.copy2(ROOT/'compat/dynamic-libraries/guest'/name,out/'guest'/name)
subprocess.run(['python3',str(out/'rebuild_llvm.py'),'--llvm-source',str(a.llvm_source.resolve()),'--jobs',str(a.jobs)],check=True)
if source_hashes()!=inputs:raise SystemExit('Provider sources changed during the build; nothing staged')
archive=out/'lib-iphoneos/libHGOnDeviceShader.a';destination=ROOT/'ios/deps/lib';destination.mkdir(parents=True,exist_ok=True)
shutil.copy2(archive,destination/archive.name)
receipt={'source_package':inputs,'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'compiler_recipe':json.loads((out/'compiler-recipe.json').read_text())}
(out/'henge-install-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
staged=destination/'libHGOnDeviceShader.build.json';temporary=staged.with_suffix('.tmp')
temporary.write_text(json.dumps(receipt,indent=2)+'\n');os.replace(temporary,staged)
subprocess.run(['python3',str(ROOT/'tools/compat/check_ondevice_provider.py')],check=True)
print(destination/archive.name)
