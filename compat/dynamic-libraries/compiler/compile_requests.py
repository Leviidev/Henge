#!/usr/bin/env python3
"""Local offline compiler for API adapter requests; no network/device operations."""
from pathlib import Path
import argparse,json,base64,hashlib,shutil
from closure import build,library,Rejected,sha
from lower_closures import lower
from recipe import verify
from toolchain import compilation_deadline
RECIPE=verify()
def compile_one(request,ready,work):
 compilation_deadline(45)
 raw=request.read_bytes();key=sha(raw)
 if request.stem!=key or len(raw)>24*1024*1024:raise Rejected('request identity/size mismatch')
 r=json.loads(raw)
 if r.get('schema')!=1 or r.get('recipe')!=RECIPE:raise Rejected('request recipe mismatch')
 w=work/key;w.mkdir(parents=True,exist_ok=True);count=0
 def unpack(row):
  nonlocal count
  b=base64.b64decode(row['source_base64'],validate=True);count+=len(b)
  if count>16*1024*1024 or len(b)>16*1024*1024 or sha(b)!=row['sha256']:raise Rejected('source identity/size mismatch')
  p=w/(row['sha256']+'.metallib');p.write_bytes(b);return {'file':str(p),'sha256':row['sha256'],'origin_url':row['origin_url']}
 if len(r['libraries'])>16:raise Rejected('dependency count exceeded')
 m={'consumer':unpack(r['consumer']),'libraries':[unpack(x)for x in r['libraries']],'preloaded_sha256':r['preloaded_sha256']}
 parsed=[library(x) for x in m['libraries']];names=[x['install_name'] for x in parsed]
 for name in r['compile_install_names']:
  if name not in names:raise Rejected('missing compile dependency identity')
  if not name.startswith('/'):raise Rejected('prototype requires absolute compile dependency origin')
 (w/'manifest.json').write_text(json.dumps(m,indent=2));build(m,w/'linked');lower(w/'linked',w/'lowered')
 output=(w/'lowered/closure.metallib').read_bytes();record=library({'file':str(w/'lowered/closure.metallib'),'sha256':sha(output)})['record']
 if [f['name']for f in record['functions']]!=[r['function_name']]:raise Rejected('function inventory unsupported')
 receipt={'schema':1,'recipe':RECIPE,'request_sha256':key,'output_sha256':sha(output),'output_bytes':len(output),'status':'ready','work_evidence':str(w)}
 ready.mkdir(parents=True,exist_ok=True);tmp=ready/(key+'.metallib.tmp');tmp.write_bytes(output);tmp.replace(ready/(key+'.metallib'));tmp=ready/(key+'.json.tmp');tmp.write_text(json.dumps(receipt,indent=2)+'\n');tmp.replace(ready/(key+'.json'));return receipt
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('requests',type=Path);p.add_argument('ready',type=Path);p.add_argument('--work',type=Path,required=True);a=p.parse_args();result=[]
 for req in sorted(a.requests.glob('*.json')):
  try:result.append(compile_one(req,a.ready,a.work))
  except Exception as e:
   r=dict(schema=1,recipe=RECIPE,request_sha256=sha(req.read_bytes()),status='rejected',error=str(e));a.ready.mkdir(parents=True,exist_ok=True);(a.ready/(req.stem+'.json')).write_text(json.dumps(r,indent=2)+'\n');result.append(r)
 print(json.dumps(result,indent=2))
