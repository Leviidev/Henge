#!/usr/bin/env python3
"""Build the pinned source-only provider in a new isolated directory, then stage its library."""
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--llvm-source',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--jobs',type=int,default=4)
a=p.parse_args();source=ROOT/'compat/ondevice-shaders';out=a.output.resolve()
if out.exists():raise SystemExit('Choose a new output directory; existing builds are preserved')
for name in ['HGOnDeviceShaderProvider.h','pvg_shader_profile.h']:
 if (source/name).read_bytes()!=(ROOT/'devices'/name).read_bytes():raise SystemExit('Provider/API contract differs: '+name)
out.mkdir(parents=True)
for item in source.iterdir():
 if item.is_file() and item.name not in ['README.md','.gitignore']:shutil.copy2(item,out/item.name)
subprocess.run(['python3',str(out/'rebuild_llvm.py'),'--llvm-source',str(a.llvm_source.resolve()),'--jobs',str(a.jobs)],check=True)
archive=out/'lib-iphoneos/libHGOnDeviceShader.a';destination=ROOT/'ios/deps/lib';destination.mkdir(parents=True,exist_ok=True)
shutil.copy2(archive,destination/archive.name)
receipt={'source_package':{x.name:hashlib.sha256(x.read_bytes()).hexdigest()for x in source.iterdir()if x.is_file()},'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'compiler_recipe':json.loads((out/'compiler-recipe.json').read_text())}
(out/'henge-install-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(destination/archive.name)
