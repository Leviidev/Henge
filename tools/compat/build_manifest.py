#!/usr/bin/env python3
"""Record source/toolchain/dependency identities without device IDs or credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--husk',type=Path,default=Path(os.environ.get('HUSK',Path.home()/'Documents/Coding/Husk')))
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();husk=a.husk.resolve();files={}
    names=run('git','ls-files','--cached','--others','--exclude-standard',cwd=ROOT).splitlines()
    for name in sorted(set(names)):
        path=ROOT/name
        if path.is_file() and path.resolve()!=a.output.resolve(): files[name]=sha(path)
    deps={}
    for rel in ['build/ios-arm64/lib/libhusk_rppairing.a']+[f'build/ios-arm64/sysroot/lib/{name}.a'for name in ['libslirp','libglib-2.0','libintl','libpcre2-8']]:
        path=husk/rel
        if not path.is_file():raise SystemExit(f'Missing configured Husk input: {rel}')
        deps[rel]=sha(path)
    for path in sorted((husk/'src/app/Frameworks/StikJIT.xcframework').rglob('*')):
        if path.is_file():deps[str(path.relative_to(husk))]=sha(path)
    tools={}
    for name in ['clang','metal','metallib','air-lld']:
        path=Path(run('xcrun','--sdk','iphoneos','--find',name));tools[name]={'sha256':sha(path)}
    value={'schema':1,'source_commit':run('git','rev-parse','HEAD',cwd=ROOT),
           'source_tree_sha256':hashlib.sha256(json.dumps(files,sort_keys=True).encode()).hexdigest(),
           'source_files':files,'xcode':run('xcodebuild','-version'),
           'iphoneos_sdk_version':run('xcrun','--sdk','iphoneos','--show-sdk-version'),
           'iphoneos_sdk_build':run('xcrun','--sdk','iphoneos','--show-sdk-build-version'),
           'macosx_sdk_version':run('xcrun','--sdk','macosx','--show-sdk-version'),
           'clang_version':run('clang','--version').splitlines()[0],
           'xcodegen':run('xcodegen','--version'),'compiler_files':tools,
           'husk_commit':run('git','rev-parse','HEAD',cwd=husk),
           'husk_dirty':bool(run('git','status','--porcelain',cwd=husk)),
           'husk_build_inputs':deps,
           'scope':'Build-input identity, not a byte-identical IPA/signature guarantee; no credentials or device identities recorded.'}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(value,indent=2)+'\n')
if __name__=='__main__':main()
