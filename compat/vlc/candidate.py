#!/usr/bin/env python3
"""Create a signed isolated VLC candidate. Never writes to the installed/source app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools/compat'))
from ipad_update import normalized_macho
from promote import tree

NAMES=['libaacdecgap_plugin.dylib','libaacgap_plugin.dylib','libaacpacketgap_plugin.dylib','libavgap_plugin.dylib','libmacosx_plugin.dylib','libmux_mp4_plugin.dylib','libsamplerate_plugin.dylib','libstream_out_transcode_plugin.dylib','libx265_plugin.dylib']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source-app',type=Path,required=True);p.add_argument('--build',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();source=a.source_app.resolve();build=a.build.resolve();out=a.output.resolve()
 if out.exists():raise SystemExit('Candidate output must not exist')
 receipt=json.loads((build/'build-receipt.json').read_text());assert sorted(receipt['plugins'])==NAMES
 info=plistlib.loads((source/'Contents/Info.plist').read_bytes());assert info['CFBundleShortVersionString']=='3.0.24'and info['CFBundleIdentifier']=='org.videolan.vlc'
 assert sha(source/'Contents/MacOS/lib/libvlccore.dylib')==receipt['reference_core_sha256']
 for name in NAMES:assert sha(build/'plugins'/name)==receipt['plugins'][name]
 out.mkdir(parents=True);manifest={'source_tree':tree(source),'source_main_normalized':normalized_macho((source/'Contents/MacOS/VLC').read_bytes()),'source_Info_sha256':sha(source/'Contents/Info.plist'),'source_plugins':receipt['plugins'],'source_plugin_content':{n:normalized_macho((build/'plugins'/n).read_bytes())for n in NAMES},'source_build_receipt_sha256':sha(build/'build-receipt.json')}
 with tempfile.TemporaryDirectory(prefix='henge-vlc-candidate-')as temporary:
  app=Path(temporary)/'VLC Export Test.app';shutil.copytree(source,app,symlinks=True)
  for name in NAMES:shutil.copyfile(build/'plugins'/name,app/'Contents/MacOS/plugins'/name)
  (app/'Contents/MacOS/plugins/plugins.dat').unlink(missing_ok=True)
  subprocess.run(['xattr','-cr',str(app)],check=True)
  with(out/'codesign.log').open('w')as log:
   subprocess.run(['codesign','--force','--deep','--sign','-','--preserve-metadata=entitlements',str(app)],stdout=log,stderr=log,check=True)
   subprocess.run(['codesign','--verify','--deep','--strict',str(app)],stdout=log,stderr=log,check=True)
  assert normalized_macho((app/'Contents/MacOS/VLC').read_bytes())==manifest['source_main_normalized']
  assert sha(app/'Contents/Info.plist')==manifest['source_Info_sha256']
  for n in NAMES:assert normalized_macho((app/'Contents/MacOS/plugins'/n).read_bytes())==manifest['source_plugin_content'][n]
  manifest['signed_plugins']={n:sha(app/'Contents/MacOS/plugins'/n)for n in NAMES}
  shutil.move(str(app),out/app.name)
  subprocess.run(['codesign','--verify','--deep','--strict',str(out/app.name)],check=True)
 assert tree(source)==manifest['source_tree']
 (out/'vlc-export.ini').write_text('[avcodec]\navcodec-hurry-up=0\n[core]\ncodec=avcodec\n')
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(out)
if __name__=='__main__':main()
