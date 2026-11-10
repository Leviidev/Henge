#!/usr/bin/env python3
"""Export a committed source-only patch series and verify clean application."""
import argparse,hashlib,json,os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def git(*args,cwd=ROOT):return subprocess.check_output(['git',*args],cwd=cwd,text=True).strip()
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--base',required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();base=git('rev-parse',a.base);head=git('rev-parse','HEAD');out=a.output.resolve()
 if git('status','--porcelain'):raise SystemExit('Commit or isolate source changes before export')
 if out.exists():raise SystemExit('Output must be new')
 subprocess.run(['git','merge-base','--is-ancestor',base,head],cwd=ROOT,check=True)
 for line in git('diff','--numstat',base,head).splitlines():
  if line.startswith('-\t-\t'):raise SystemExit('Binary changes are excluded from this source series')
 out.mkdir(parents=True);patches=out/'patches';patches.mkdir();git('format-patch','--no-signature','--output-directory',str(patches),base+'..'+head)
 files=sorted(patches.glob('*.patch'));assert files
 env=os.environ.copy();env.update(GIT_COMMITTER_NAME='Henge patch verification',GIT_COMMITTER_EMAIL='patch-verification@localhost')
 with tempfile.TemporaryDirectory(prefix='henge-patch-apply-')as temp:
  clone=Path(temp)/'source'
  with(out/'apply.log').open('w')as log:
   subprocess.run(['git','clone','--shared','--no-checkout',str(ROOT),str(clone)],stdout=log,stderr=log,check=True)
   subprocess.run(['git','checkout','--detach',base],cwd=clone,stdout=log,stderr=log,check=True)
   subprocess.run(['git','am',*[str(x)for x in files]],cwd=clone,env=env,stdout=log,stderr=log,check=True)
  expected=git('rev-parse',head+'^{tree}');actual=git('rev-parse','HEAD^{tree}',cwd=clone)
  if actual!=expected:raise ValueError('Applied tree differs from staging tree')
 names=git('diff','--name-only',base,head).splitlines();hashes={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest()for name in names if(ROOT/name).is_file()}
 value={'schema':1,'base':base,'head':head,'tree':expected,'clean_apply_tree':actual,'clean_apply_passed':True,'commits':git('log','--reverse','--format=%H %s',base+'..'+head).splitlines(),'patches':{x.name:hashlib.sha256(x.read_bytes()).hexdigest()for x in files},'changed_source_files':hashes,'scope':'Source patches only; clean application does not establish device/runtime compatibility.'}
 (out/'manifest.json').write_text(json.dumps(value,indent=2)+'\n');print(out)
if __name__=='__main__':main()
