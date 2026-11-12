#!/usr/bin/env python3
"""Build in-process compiler/provider archives and source-bound embedded recipe."""
from pathlib import Path
import subprocess,json,hashlib,shlex
root=Path(__file__).resolve().parent;log=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(cmd):
 p=subprocess.run(cmd,cwd=root,capture_output=True,text=True);log.append(dict(command=cmd,exit=p.returncode,stderr=p.stderr));(root/'build-provider.json').write_text(json.dumps(log,indent=2)+'\n');assert p.returncode==0,p.stderr
libs=subprocess.check_output([str(root/'llvm-native/bin/llvm-config'),'--libnames','bitreader','bitwriter140','bitwriter','core'],text=True).split()
platforms=[('macosx','llvm-native','arm64-apple-macos14.0'),('iphoneos','llvm-ios','arm64-apple-ios17.0')]
flags={}
for sdk,build,target in platforms:
 out=root/('lib-'+sdk);out.mkdir(exist_ok=True);sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip();flags[sdk]=['-target',target,'-isysroot',sdkpath,'-std=c++20','-O2','-frtti','-fexceptions','-DHENGE_AIR_EMBEDDED=1','-I'+str(root/'llvm-source/llvm/include'),'-I'+str(root/build/'include'),'-D__STDC_CONSTANT_MACROS','-D__STDC_FORMAT_MACROS','-D__STDC_LIMIT_MACROS']
 run(['xcrun','--sdk',sdk,'clang++',*flags[sdk],'-c','HGOnDeviceAIR.cpp','-o',str(out/'HGOnDeviceAIR.o')])
 run(['xcrun','libtool','-static','-o',str(out/'libHGOnDeviceCompiler.a'),str(out/'HGOnDeviceAIR.o'),*[str(root/build/'lib'/n)for n in libs]])
 run(['xcrun','nmedit','-D','-p','-s','HGOnDeviceCompiler.exports',str(out/'libHGOnDeviceCompiler.a')])
source_names=['HGOnDeviceAIR.cpp','HGOnDeviceAIR.h','air_transform.cpp','HGOnDeviceShaderProvider.mm','HGOnDeviceShaderProvider.h','pvg_shader_profile.h','llvm-air-embedding.patch','harden_llvm.py','build_provider.py','HGOnDeviceCompiler.exports']
manifest=dict(schema=1,provider='ondevice-llvm14',protocol=3,target='air64-apple-ios17.0.0',llvm_repository='https://github.com/gzorin/floor_llvm',llvm_commit='6a133d69154dfaffa04a6339a3178db328bd98a5',llvm_options=dict(exceptions=True,rtti=True,threads=False,embedded_unreachable_recoverable=True),sdk_build=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-build-version'],text=True).strip(),source_sha256={n:sha(root/n)for n in source_names},compiler_archive_sha256={sdk:sha(root/('lib-'+sdk)/'libHGOnDeviceCompiler.a')for sdk,_,_ in platforms},limits=dict(input_bytes=8*1024*1024,output_bytes=16*1024*1024,pending_jobs=8,pending_input_bytes=32*1024*1024,ready_entries=128,ready_output_bytes=32*1024*1024,reader_operations=1000000,cooperative_reader_milliseconds=5000))
encoded=json.dumps(manifest,sort_keys=True,separators=(',',':')).encode();recipe=hashlib.sha256(encoded).hexdigest();(root/'HGOnDeviceCompilerRecipe.h').write_text('#pragma once\n#define HG_ONDEVICE_COMPILER_RECIPE "'+recipe+'"\nstatic const char HGOnDeviceCompilerRecipeJSON[] = '+json.dumps(encoded.decode())+';\n');(root/'compiler-recipe.json').write_text(json.dumps(dict(recipe=recipe,manifest=manifest),indent=2)+'\n')
for sdk,_,_ in platforms:
 out=root/('lib-'+sdk)
 run(['xcrun','--sdk',sdk,'clang++',*flags[sdk],'-fobjc-arc','-c','HGOnDeviceShaderProvider.mm','-o',str(out/'HGOnDeviceShaderProvider.o')])
 run(['xcrun','libtool','-static','-o',str(out/'libHGOnDeviceShader.a'),str(out/'HGOnDeviceShaderProvider.o'),str(out/'libHGOnDeviceCompiler.a')])
run(['xcrun','--sdk','macosx','clang++',*flags['macosx'],'-fobjc-arc','-DHG_PROVIDER_TESTING=1','-DHG_PROVIDER_PENDING_LIMIT=2','HGOnDeviceShaderProvider.mm','native_provider_tests.mm',str(root/'lib-macosx/libHGOnDeviceCompiler.a'),'-Wl,-dead_strip','-framework','Foundation','-framework','Metal','-o','native_provider_tests'])
print(json.dumps(dict(recipe=recipe,ios_archive_sha256=sha(root/'lib-iphoneos/libHGOnDeviceShader.a')),indent=2))
