#!/usr/bin/env python3
"""Build-only LLVM preparation. No network, device actions or runtime service."""
import argparse,json,subprocess,shutil,hashlib,os
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--llvm-source',type=Path,required=True);p.add_argument('--jobs',type=int,default=4);a=p.parse_args()
r=Path(__file__).resolve().parent;s=a.llvm_source.resolve();pin='6a133d69154dfaffa04a6339a3178db328bd98a5'
def output(c):return subprocess.check_output(c,text=True).strip()
def run(c):subprocess.run(c,cwd=r,check=True)
assert output(['git','-C',str(s),'rev-parse','HEAD'])==pin,'wrong LLVM commit'
assert not output(['git','-C',str(s),'status','--porcelain','--untracked-files=no']),'LLVM source has tracked modifications'
assert not (r/'llvm-source').exists(),'use a fresh source-package directory; never overwrite a build'
assert 1<=a.jobs<=32
for name in ['llvm','cmake']:shutil.copytree(s/name,r/'llvm-source'/name,symlinks=True)
run(['python3','harden_llvm.py'])
common=['-G','Ninja','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_CXX_FLAGS=-DHENGE_AIR_EMBEDDED=1','-DLLVM_ENABLE_EH=ON','-DLLVM_ENABLE_RTTI=ON','-DLLVM_ENABLE_THREADS=OFF','-DLLVM_TARGETS_TO_BUILD=','-DLLVM_ENABLE_PROJECTS=','-DLLVM_BUILD_TOOLS=OFF','-DLLVM_INCLUDE_TESTS=OFF','-DLLVM_INCLUDE_BENCHMARKS=OFF','-DLLVM_ENABLE_ZLIB=OFF','-DLLVM_ENABLE_ZSTD=OFF','-DLLVM_ENABLE_LIBXML2=OFF','-DLLVM_ENABLE_TERMINFO=OFF','-DLLVM_ENABLE_CURL=OFF']
run(['cmake','-S','llvm-source/llvm','-B','llvm-native',*common,'-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0'])
targets=['LLVMLinker','LLVMBitReader','LLVMBitWriter140','LLVMBitWriter']
run(['cmake','--build','llvm-native','-j',str(a.jobs),'--target','llvm-config','llvm-tblgen',*targets])
run(['cmake','-S','llvm-source/llvm','-B','llvm-ios',*common,'-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_MACOSX_BUNDLE=OFF','-DCMAKE_OSX_SYSROOT=iphoneos','-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0','-DLLVM_TABLEGEN='+str(r/'llvm-native/bin/llvm-tblgen')])
run(['cmake','--build','llvm-ios','-j',str(a.jobs),'--target',*targets])
run(['python3','build_provider.py'])
