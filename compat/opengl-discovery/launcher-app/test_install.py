#!/usr/bin/env python3
"""Exercise installer on only temporary wrapper copies; never launch VLC."""
from pathlib import Path
import argparse,hashlib,json,plistlib,shutil,subprocess,tarfile,tempfile
HERE=Path(__file__).resolve().parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--archive',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
with tempfile.TemporaryDirectory(prefix='henge-wrapper-install-test-') as temporary:
 root=Path(temporary);source=root/'source';source.mkdir()
 with tarfile.open(a.archive) as archive:archive.extractall(source)
 app=next(source.glob('*.app'));destination=root/'Installed Apps'
 command=['/bin/bash',str(HERE/'install.sh'),str(app),str(destination)]
 first=subprocess.run(command,text=True,capture_output=True,check=True)
 second=subprocess.run(command,text=True,capture_output=True,check=True)
 (out/'install.log').write_text(first.stdout+first.stderr+second.stdout+second.stderr)
 backup=Path(next(s.split(': ',1)[1] for s in second.stdout.splitlines() if s.startswith('Previous wrapper backup: ')))
 assert backup.parent.parent==Path.home()/'Library/Application Support/Henge/LauncherBackups'
 installed=destination/app.name
 hashes=lambda path:{str(f.relative_to(path)):sha(f) for f in path.rglob('*') if f.is_file()}
 expected=hashes(app);assert hashes(installed)==expected and hashes(backup)==expected
 subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(installed)],check=True,capture_output=True)
 # Remove only the unique backup of our temporary test wrapper after checking.
 shutil.rmtree(backup.parent)
 collision=root/'Collision'/app.name;(collision/'Contents').mkdir(parents=True)
 marker=collision/'Contents/Info.plist';marker.write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.example.original','CFBundleName':'Keep Me'}))
 old=sha(marker)
 refused=subprocess.run(['/bin/bash',str(HERE/'install.sh'),str(app),str(collision.parent)],text=True,capture_output=True)
 assert refused.returncode==65 and sha(marker)==old
 (out/'collision.log').write_text(refused.stdout+refused.stderr)
 (out/'result.json').write_text(json.dumps({'fresh_install':True,'matching_wrapper_backed_up':True,
  'backup_and_installed_files_match_source':True,'installed_signature_valid':True,
  'other_app_collision_refused':True,'other_app_hash_unchanged':True,
  'temporary_test_backup_removed':True,'target_app_modified':False,'device_actions':False},indent=2)+'\n')
print('PASS fresh install, backup replacement, signed copies, unrelated app refusal')
