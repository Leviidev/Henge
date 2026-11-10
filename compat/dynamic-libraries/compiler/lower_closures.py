from pathlib import Path
import json,subprocess,re
from toolchain import run as tool_run,output as tool_output,llvm_tool,close_tool
from closure import inspect_metallib,sha
p=Path(__file__).resolve().parent
def lower(src,dst):
 src=Path(src);dst=Path(dst);dst.mkdir(parents=True,exist_ok=True)
 b=(src/'closure.metallib').read_bytes();r=inspect_metallib(b);mods=[];commands=[]
 def run(cmd):
  q=tool_run(cmd);commands.append(dict(command=cmd,returncode=q.returncode,stdout=q.stdout,stderr=q.stderr));(dst/'commands.json').write_text(json.dumps(commands,indent=2));assert q.returncode==0,q.stderr
 for i,a in enumerate(r['air_regions']):
  raw=dst/f'{i}-before.air';raw.write_bytes(b[a['offset']:a['offset']+a['size']]);check=dst/f'{i}-verified-llvm23.air'
  # LLVM graph validation, not bytes sent to Apple: current LLVM writer is newer than Apple reader.
  run([close_tool(),str(raw),str(check)])
  ll=dst/f'{i}-apple-original.ll'
  # Preserve AIR profile and native Apple IR spelling; no attribute/type normalization.
  decoded=tool_output([llvm_tool('llvm-dis'),str(raw),'-o','-'])
  target=re.search(r'target triple = "([^"]+)"',decoded)[1]
  run(['xcrun','--sdk','macosx','metal','-x','ir','-S','-emit-llvm',str(raw),'-target',target,'-o',str(ll)])
  before=ll.read_text();lines=before.splitlines(keepends=True)
  remove=[x for x in lines if x.startswith(('@air.dyld_lib_table =','@air.dyld_str_table =','@air.dyld_flat_table ='))]
  used=[x for x in lines if x.startswith('@llvm.used =')]
  if remove:
   assert len(used)==1
   refs=set(re.findall(r'@([a-zA-Z0-9_.$]+)',used[0]))-{'llvm.used'}
   assert refs and refs<= {'air.dyld_flat_table','air.dyld_lib_table','air.dyld_str_table'},refs
   remove+=used
  after=''.join(x for x in lines if x not in remove)
  transformed=dst/f'{i}-apple-closed.ll';transformed.write_text(after)
  (dst/f'{i}-removed-lines.txt').write_text(''.join(remove))
  assert all(not x.startswith('@air.dyld_') for x in after.splitlines())
  air=dst/f'{i}-closed-apple.air'
  run(['xcrun','--sdk','macosx','metal','-x','ir','-c',str(transformed),'-target',target,'-o',str(air)])
  # Verify Apple output has no routing globals and retains concrete helper definition.
  output_ir=tool_output([llvm_tool('llvm-dis'),str(air),'-o','-'])
  assert '@air.dyld_' not in output_ir
  (dst/f'{i}-final.ll').write_text(output_ir);mods.append(str(air))
 ver='.'.join(map(str,r['header']['target_os_version']))
 run(['xcrun','--sdk','macosx','air-lld','--arch','air64','--macos_version_min',ver,*mods,'-o',str(dst/'closure.metallib')])
 output=(dst/'closure.metallib').read_bytes();check=inspect_metallib(output);assert not check['malformed_records'] and not check['integrity_mismatches']
 assert [(f['name'],f['type_raw']) for f in check['functions']]==[(f['name'],f['type_raw']) for f in r['functions']]
 (dst/'lowering.json').write_text(json.dumps({'original_closed_graph_sha256':sha(b),'output_sha256':sha(output),'commands':commands,'input_provenance':str(src/'link.json'),'scope':'remove linker routing tables only after every flat-table import resolves to local function definition; original artifacts untouched; typed Apple IR spelling retained'},indent=2)+'\n')

if __name__=='__main__':
 for name in ['loader_file','absolute_source','preloaded_only']:lower(p/'closures'/name,p/'lowered'/name)
