#!/usr/bin/env python3
"""Guarded local promotion/rollback of a tested VLC candidate; never auto-run.

Use only after separate guest GUI validation. Requires the app to be closed.
Backups and receipts remain private. No security or renderer configuration change.
"""
import argparse,hashlib,json,os,plistlib,re,shutil,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools/compat'))
from ipad_update import normalized_macho

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def tree(app):
 return {str(p.relative_to(app)):('symlink:'+os.readlink(p)if p.is_symlink()else sha(p))for p in sorted(app.rglob('*'))if p.is_file()or p.is_symlink()}
def inactive(app):
 executable=str(app/'Contents/MacOS/VLC')
 output=subprocess.check_output(['ps','-axo','command='],text=True)
 if any(line.strip()==executable or line.strip().startswith(executable+' ')for line in output.splitlines()):raise ValueError('Close the target VLC process before promotion or rollback')
def merged_config(text):
 # VLC reads these known keys globally; preserve all unrelated text/comments.
 values={'codec':'avcodec','avcodec-hurry-up':'0'};seen=set();lines=[]
 for line in text.splitlines(keepends=True):
  match=re.match(r'^\s*(codec|avcodec-hurry-up)\s*=',line)
  if match:
   key=match[1]
   if key not in seen:lines.append(key+'='+values[key]+'\n');seen.add(key)
  else:lines.append(line)
 if lines and not lines[-1].endswith('\n'):lines[-1]+='\n'
 for key in values:
  if key not in seen:lines.append(key+'='+values[key]+'\n')
 return ''.join(lines)
def write_json(p,data):p.write_text(json.dumps(data,indent=2)+'\n')
def main():
 parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='action',required=True)
 p=sub.add_parser('install');p.add_argument('--candidate',type=Path,required=True);p.add_argument('--app',type=Path,required=True);p.add_argument('--config',type=Path,required=True);p.add_argument('--backup',type=Path,required=True);p.add_argument('--validated-gui-receipt',type=Path,required=True)
 p=sub.add_parser('restore');p.add_argument('--backup',type=Path,required=True);p.add_argument('--retain-current',type=Path,required=True)
 a=parser.parse_args();backup=a.backup.resolve()
 if a.action=='install':
  app=a.app.resolve();candidate=a.candidate.resolve();config=a.config.resolve();manifest=json.loads((candidate/'manifest.json').read_text());source=candidate/'VLC Export Test.app';inactive(app)
  if app.suffix!='.app'or backup.exists():raise ValueError('Existing app and new backup directory required')
  if 'source_tree'not in manifest:raise ValueError('Regenerate candidate with current candidate.py to record its full source tree')
  if tree(app)!=manifest['source_tree']:raise ValueError('Installed app changed since candidate preparation')
  if sha(source/'Contents/Info.plist')!=manifest['source_Info_sha256']or normalized_macho((source/'Contents/MacOS/VLC').read_bytes())!=manifest['source_main_normalized']:raise ValueError('Candidate changed Info/main code or load commands')
  for name,digest in manifest['signed_plugins'].items():
   if sha(source/'Contents/MacOS/plugins'/name)!=digest:raise ValueError('Candidate plugin hash mismatch')
  subprocess.run(['codesign','--verify','--deep','--strict',str(source)],check=True)
  # Receipt is user-supplied evidence, bound by hash; this tool does not infer GUI success.
  if not a.validated_gui_receipt.is_file():raise ValueError('Separate GUI validation receipt required')
  backup.parent.mkdir(parents=True,exist_ok=True)
  if backup.parent.stat().st_dev!=app.parent.stat().st_dev:raise ValueError('Backup must be on same filesystem for reversible rename')
  backup.mkdir(mode=0o700);staged=app.with_name(app.name+'.henge-staged')
  if staged.exists():raise ValueError('Staging path already exists')
  config_before=config.read_bytes()if config.exists()else None
  if config_before is not None:(backup/'vlcrc.before').write_bytes(config_before)
  newconfig=merged_config((config_before or b'').decode('utf-8')).encode('utf-8')
  shutil.copytree(source,staged,symlinks=True)
  candidate_tree=tree(staged)
  if candidate_tree!=tree(source):raise ValueError('Staged candidate copy mismatch')
  receipt={'schema':1,'app':str(app),'config':str(config),'original_tree':manifest['source_tree'],'candidate_tree':candidate_tree,'config_existed':config_before is not None,'config_before_sha256':hashlib.sha256(config_before).hexdigest()if config_before is not None else None,'config_after_sha256':hashlib.sha256(newconfig).hexdigest(),'candidate_manifest_sha256':sha(candidate/'manifest.json'),'gui_validation_receipt_sha256':sha(a.validated_gui_receipt),'state':'prepared'}
  write_json(backup/'receipt.json',receipt);inactive(app)
  if tree(app)!=receipt['original_tree']:raise ValueError('Target changed during preparation')
  os.rename(app,backup/'VLC.app')
  try:
   os.rename(staged,app);config.parent.mkdir(parents=True,exist_ok=True);temporary=config.with_name(config.name+'.henge-new')
   with temporary.open('xb')as f:f.write(newconfig)
   os.chmod(temporary,config.stat().st_mode & 0o777 if config.exists()else 0o600)
   os.replace(temporary,config)
  except Exception:
   if app.exists():os.rename(app,backup/'failed-candidate.app')
   os.rename(backup/'VLC.app',app);raise
  receipt['state']='installed';write_json(backup/'receipt.json',receipt)
 else:
  receipt=json.loads((backup/'receipt.json').read_text());app=Path(receipt['app']);config=Path(receipt['config']);retain=a.retain_current.resolve();inactive(app)
  if receipt['state']!='installed'or retain.exists():raise ValueError('Installed receipt and new retention path required')
  if tree(app)!=receipt['candidate_tree']or tree(backup/'VLC.app')!=receipt['original_tree']:raise ValueError('App content changed; review before restoring')
  if not config.exists()or sha(config)!=receipt['config_after_sha256']:raise ValueError('Preferences changed since install; merge them before manual rollback')
  retain.parent.mkdir(parents=True,exist_ok=True)
  if retain.parent.stat().st_dev!=app.parent.stat().st_dev:raise ValueError('Retention path must be on same filesystem')
  os.rename(app,retain)
  try:os.rename(backup/'VLC.app',app)
  except Exception:os.rename(retain,app);raise
  if receipt['config_existed']:shutil.copyfile(backup/'vlcrc.before',config)
  else:config.unlink()
  receipt['state']='restored';receipt['retained_candidate']=str(retain);write_json(backup/'receipt.json',receipt)
if __name__=='__main__':main()
