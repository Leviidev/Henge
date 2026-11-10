#!/usr/bin/env python3
"""Experimental stateless AIR dependency closure. Never changes input bytes.
Explicit manifest only: does not search arbitrary filesystem dependencies.
Not an MTLDynamicLibrary implementation; resolves a bounded pipeline snapshot.
"""
import hashlib,json,struct,subprocess,sys,re
from pathlib import Path
ROOT=Path(__file__).resolve().parent
from metallib_catalog import inspect_metallib,tags_at
import posixpath
from toolchain import run as tool_run,output,llvm_tool

class Rejected(ValueError):pass
def sha(b):return hashlib.sha256(b).hexdigest()
def library(entry):
 p=Path(entry['file']);b=p.read_bytes()
 if sha(b)!=entry['sha256']:raise Rejected('source digest mismatch')
 r=inspect_metallib(b)
 if r['format']!='metallib' or r['malformed_records'] or r['integrity_mismatches'] or not r['air_regions']:raise Rejected('invalid or unreviewed AIR library')
 names=[];deps=[]
 for t in r['unsupported_records']:
  if t['scope']=='header_extension' and t['tag']=='HDYN':
   off,n=struct.unpack('<QQ',bytes.fromhex(t['data_hex']))
   if off+n>len(b):raise Rejected('HDYN bounds')
   tags,end=tags_at(b,off,off+n)
   if end!=off+n:raise Rejected('HDYN trailing bytes')
   for t in tags:
    if t['tag'] not in ('NAME','DYNL') or not t['data'].endswith(b'\0') or b'\0' in t['data'][:-1]:raise Rejected('unsupported dynamic header')
    (names if t['tag']=='NAME' else deps).append(t['data'][:-1].decode())
 if len(names)>1:raise Rejected('multiple install names')
 return dict(entry,bytes=b,record=r,install_name=names[0] if names else None,dependencies=deps)
def resolve(manifest):
 root=library(manifest['consumer']);pool=[library(x) for x in manifest['libraries']]
 byname={};byurl={}
 for l in pool:
  name=l['install_name']
  if not name or l['record']['header']['library_type_raw']!=2:raise Rejected('dependency is not dynamic AIR library')
  if name in byname and byname[name]['sha256']!=l['sha256']:raise Rejected('ambiguous install name')
  byname[name]=l
  if l.get('origin_url'):byurl[posixpath.normpath(l['origin_url'])]=l
 selected=[];seen=set();active=set()
 def visit(l):
  key=l['sha256']
  if key in active:raise Rejected('dependency cycle not supported by prototype')
  if key in seen:return
  active.add(key)
  for dep in l['dependencies']:
   if dep.startswith('@loader_path/'):
    if not l.get('origin_url'):raise Rejected('loader path requires consumer file origin')
    resolved=posixpath.normpath(posixpath.join(posixpath.dirname(l['origin_url']),dep[len('@loader_path/'):]));d=byurl.get(resolved)
   elif dep.startswith('@executable_path/'):
    # Native v4 evidence: source consumer has no URL; preserve this rejection.
    if not l.get('origin_url'):raise Rejected('executable path requires consumer file origin')
    raise Rejected('executable path resolution not implemented by bounded prototype')
   elif dep.startswith('@'):raise Rejected('rpath or unknown expansion not implemented')
   else:d=byname.get(dep) if Path(dep).is_absolute() else None
   if d is None:raise Rejected('missing declared dependency: '+dep)
   if d['install_name']!=dep:raise Rejected('install-name identity mismatch')
   visit(d)
  active.remove(key);seen.add(key)
  if l is not root:selected.append(l)
 visit(root)
 for ident in manifest.get('preloaded_sha256',[]):
  matches=[l for l in pool if l['sha256']==ident]
  if not matches:raise Rejected('missing preloaded dependency')
  visit(matches[0])
 exports={}
 for l in selected:
  for f in l['record']['functions']:
   if f['type_raw']!=3:raise Rejected('dependency contains unsupported stage/visible function')
   if f['name'] in exports and exports[f['name']]!=l['sha256']:raise Rejected('duplicate export requires dynamic namespace semantics')
   exports[f['name']]=l['sha256']
 if len(selected)>16:raise Rejected('dependency bound exceeded')
 return root,selected

def build(manifest,out):
 out=Path(out);out.mkdir(parents=True,exist_ok=True);root,deps=resolve(manifest)
 modules=[];records=[]
 for li,l in enumerate([root,*deps]):
  for mi,a in enumerate(l['record']['air_regions']):
   p=out/f'{li}-{mi}.air';p.write_bytes(l['bytes'][a['offset']:a['offset']+a['size']])
   ll=p.with_suffix('.ll');run=tool_run([llvm_tool('llvm-dis'),str(p),'-o',str(ll)])
   if run.returncode:raise Rejected('LLVM decode failed: '+run.stderr)
   text=ll.read_text()
   if li:
    # Stateless subset: reject mutable/user globals, aliases/ifuncs and indirect calls.
    globals=[x for x in text.splitlines() if x.startswith('@') and not x.startswith(('@air.dyld_lib_table =','@air.dyld_str_table =','@air.dyld_flat_table =','@llvm.used =','@llvm.compiler.used ='))]
    if globals:raise Rejected('dependency global storage/alias unsupported: '+globals[0])
    if re.search(r'\b(?:call|invoke)\b[^\n]* %[-\w.]+\(',text):raise Rejected('indirect function call unsupported')
   modules.append(str(p));records.append({'source_sha256':l['sha256'],'module_offset':a['offset'],'module_size':a['size'],'module_sha256':sha(p.read_bytes())})
 if len(modules)>64:raise Rejected('module bound exceeded')
 target=max(l['record']['header']['target_os_version'] for l in [root,*deps])
 platforms={l['record']['header']['target_os'] for l in [root,*deps]}
 if platforms!={'macOS'}:raise Rejected('prototype only validated macOS closure')
 version='.'.join(map(str,target));output=out/'closure.metallib'
 cmd=['xcrun','--sdk','macosx','air-lld','--arch','air64','--macos_version_min',version,*modules,'-o',str(output)]
 run=tool_run(cmd)
 evidence={'command':cmd,'returncode':run.returncode,'stdout':run.stdout,'stderr':run.stderr,'modules':records,'consumer_sha256':root['sha256'],'dependency_sha256':[l['sha256'] for l in deps],'stateless_only':True,'dynamic_api_implemented':False}
 if run.returncode:
  (out/'link.json').write_text(json.dumps(evidence,indent=2));raise Rejected('Apple linker rejected dependency closure')
 b=output.read_bytes();r=inspect_metallib(b)
 if r['malformed_records'] or r['integrity_mismatches'] or library({'file':str(output),'sha256':sha(b)})['dependencies']:raise Rejected('link output retains unresolved dynamic header or invalid structure')
 expected=[(f['name'],f['type_raw']) for f in root['record']['functions']];actual=[(f['name'],f['type_raw']) for f in r['functions']]
 if actual!=expected:raise Rejected('consumer entrypoint inventory changed')
 evidence.update(output=str(output),output_sha256=sha(b),output_bytes=len(b),function_inventory=actual,no_declared_dynamic_dependencies=True)
 evidence['closure_key']=sha(json.dumps({'consumer':root['sha256'],'dependencies':evidence['dependency_sha256'],'platform':'macOS','min':version,'prototype_recipe':1},sort_keys=True).encode())
 (out/'link.json').write_text(json.dumps(evidence,indent=2)+'\n');return evidence
if __name__=='__main__':
 try:print(json.dumps(build(json.loads(Path(sys.argv[1]).read_text()),sys.argv[2]),indent=2))
 except Rejected as e:print(json.dumps({'status':'rejected','reason':str(e)}));sys.exit(2)
