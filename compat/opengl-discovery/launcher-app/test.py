#!/usr/bin/env python3
"""Own-target native wrapper test. No media, OpenGL context or device actions."""
from pathlib import Path
import argparse,hashlib,json,shutil,subprocess,tarfile
HERE=Path(__file__).resolve().parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--helper-dir',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
source=out/'target.c';source.write_text('#include <stdio.h>\n#include <stdlib.h>\nint main(int argc,char **argv){(void)argv; printf("owned target argc=%d discovery=%s\\n",argc,getenv("HENGE_CGL_DISCOVERY_TEST")?:"missing"); return argc==1?0:9;}\n')
target=out/'owned-target';subprocess.run(['xcrun','clang','-target','arm64-apple-macos14',str(source),'-o',str(target)],check=True)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(target)],check=True,capture_output=True)
before=sha(target)
subprocess.run(['python3',str(HERE/'build.py'),'--helper-dir',str(a.helper_dir.resolve()),'--output',str(out/'built'),
 '--name','Owned Wrapper Test','--bundle-id','org.henge.opengl.wrapper-test','--target-executable',str(target),'--target-bundle-id',''],check=True,capture_output=True)
with tarfile.open(out/'built/Owned Wrapper Test.app.tar.gz') as archive:
 archive.extractall(out/'built')
original=out/'built/Owned Wrapper Test.app';relocated=out/'relocated folder/Owned Wrapper Test.app';relocated.parent.mkdir();shutil.copytree(original,relocated)
exe=relocated/'Contents/MacOS/HengeOpenGLLauncher';logs=out/'diagnostic logs';runs=[]
for _ in range(2):
 r=subprocess.run([str(exe),'--preflight-only','--diagnostic-log-root',str(logs)],check=True,text=True,capture_output=True)
 run=Path(r.stdout.strip());receipt=json.loads((run/'receipt.json').read_text());wrapper=json.loads((run/'wrapper.json').read_text())
 assert receipt['dry_run'] and receipt['command']==[str(target)]
 assert receipt['activation']['requested'] and 'child_pid' not in receipt
 assert str(relocated/'Contents/Resources/registry-discovery.dylib') in receipt['libraries']
 assert wrapper['exit_code']==0 and not (run/'target.log').exists()
 runs.append(str(run))
assert runs[0]!=runs[1]
# Ordinary own-target launch uses the standard user Library log path. It does
# not open media or create any GPU context. Preserve its logs as evidence.
r=subprocess.run([str(exe)],check=True,text=True,capture_output=True)
normal=Path(r.stdout.strip());receipt=json.loads((normal/'receipt.json').read_text())
assert receipt['exit_code']==0 and not receipt['dry_run']
assert receipt['child_pid']>0 and receipt['launcher_pid']>0 and receipt['activation']['requested']
assert 'owned target argc=1 discovery=1' in (normal/'target.log').read_text()
assert sha(target)==before
shutil.copytree(normal,out/'normal-run-evidence')
# Only this test's unique run folder is removed from Library after archival.
shutil.rmtree(normal)
(out/'result.json').write_text(json.dumps({'schema':1,'preflight_runs':runs,'normal_run_archived':'normal-run-evidence',
 'own_target_sha256_before_after':before,'relocated_bundle_resources':True,'unique_runs':True,'normal_launch_no_forced_arguments':True,
 'no_media_or_gpu_context':True,'target_app_modified':False},indent=2)+'\n')
print('PASS relocated preflight twice, unique receipts, normal own-target launch, unchanged target')
