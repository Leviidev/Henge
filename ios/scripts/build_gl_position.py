#!/usr/bin/env python3
"""Build the metadata planner on the compiler Mac; no guest/device operations."""
import argparse,hashlib,json,os,shlex,shutil,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--llvm-config',default=os.environ.get('HENGE_LLVM_CONFIG'));p.add_argument('--output',type=Path,default=HERE/'gl-position-plan');a=p.parse_args()
config=a.llvm_config or shutil.which('llvm-config') or next((x for x in ['/opt/homebrew/opt/llvm/bin/llvm-config','/usr/local/opt/llvm/bin/llvm-config']if Path(x).is_file()),None)
if not config:p.error('LLVM development tools required; pass --llvm-config and use the same HENGE_LLVM_CONFIG for the companion')
flags=shlex.split(subprocess.check_output([config,'--cxxflags','--ldflags','--libs','core','irreader','--system-libs'],text=True));sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip();cmd=['xcrun','clang++',str(HERE/'gl_position_plan.cpp'),*flags,'-std=c++20','-isysroot',sdk,'-o',str(a.output)];q=subprocess.run(cmd,capture_output=True,text=True,timeout=90);record=dict(command=cmd,returncode=q.returncode,stdout=q.stdout,stderr=q.stderr,llvm_config=str(config));a.output.with_suffix('.build.json').write_text(json.dumps(record,indent=2)+'\n');q.check_returncode();a.output.chmod(0o755);print(hashlib.sha256(a.output.read_bytes()).hexdigest(),a.output)
