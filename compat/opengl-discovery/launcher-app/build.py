#!/usr/bin/env python3
"""Build a separate macOS14 arm64 wrapper; never modify/sign the target app."""
from pathlib import Path
import argparse,gzip,hashlib,json,plistlib,re,shutil,subprocess,tarfile,tempfile
HERE=Path(__file__).resolve().parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--helper-dir',type=Path,required=True)
 p.add_argument('--output',type=Path,required=True)
 p.add_argument('--name',default='VLC Hardware')
 p.add_argument('--bundle-id',default='org.henge.opengl.vlc-hardware')
 p.add_argument('--target-executable',default='/Applications/VLC.app/Contents/MacOS/VLC')
 p.add_argument('--target-bundle-id',default='org.videolan.vlc')
 a=p.parse_args()
 if not a.name or '/' in a.name or a.name in ['.','..'] or any(ord(c)<32 for c in a.name):p.error('Invalid app name')
 if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]+',a.bundle_id):p.error('Invalid bundle ID')
 if not Path(a.target_executable).is_absolute():p.error('Target executable must be absolute')
 helpers=a.helper_dir.resolve()
 for n in ['launch','registry-discovery.dylib']:
  if not (helpers/n).is_file():p.error('Missing helper '+n)
 out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
 workspace=tempfile.TemporaryDirectory(prefix='henge-opengl-wrapper-')
 work=Path(workspace.name)
 app=work/(a.name+'.app');contents=app/'Contents';resources=contents/'Resources';macos=contents/'MacOS'
 resources.mkdir(parents=True);macos.mkdir()
 for n in ['launch','registry-discovery.dylib']:shutil.copy2(helpers/n,resources/n)
 (resources/'launch').chmod(0o755)
 info={'CFBundlePackageType':'APPL','CFBundleExecutable':'HengeOpenGLLauncher',
  'CFBundleIdentifier':a.bundle_id,'CFBundleName':a.name,'CFBundleDisplayName':a.name,
  'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSMinimumSystemVersion':'14.0',
  'LSUIElement':True,'NSHighResolutionCapable':True,'HengeOpenGLLauncher':True,
  'HengeTargetExecutable':a.target_executable,'HengeTargetBundleIdentifier':a.target_bundle_id}
 (contents/'Info.plist').write_bytes(plistlib.dumps(info,sort_keys=True))
 compiler=subprocess.check_output(['xcrun','--find','clang'],text=True).strip()
 command=[compiler,'-target','arm64-apple-macos14','-O2','-fobjc-arc','-Wall','-Wextra','-Werror',
  str(HERE/'main.m'),'-framework','AppKit','-framework','Foundation','-o',str(macos/'HengeOpenGLLauncher')]
 with (out/'build.log').open('w') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
 # Desktop file-provider/Finder metadata can be added to newly created apps
 # and codesign rejects resource forks/FinderInfo. Remove only those two
 # metadata attributes from this newly generated bundle, never quarantine
 # or any attribute on the original helpers/target application.
 for attribute in ['com.apple.FinderInfo','com.apple.ResourceFork']:
  subprocess.run(['/usr/bin/xattr','-r','-d',attribute,str(app)],capture_output=True,check=False)
 # Sign only the new wrapper bundle. Copied, already signed helper bytes stay
 # unchanged; --deep is deliberately not used to re-sign nested executables.
 subprocess.run(['/usr/bin/codesign','--force','--sign','-','--timestamp=none','--identifier',a.bundle_id,str(app)],check=True,capture_output=True)
 subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
 for n in ['launch','registry-discovery.dylib']:
  assert sha(resources/n)==sha(helpers/n),'Signing changed copied helper bytes'
 files={str(f.relative_to(app)):sha(f) for f in sorted(app.rglob('*')) if f.is_file()}
 archive=out/(app.name+'.tar.gz')
 with archive.open('wb') as raw:
  with gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0) as compressed:
   with tarfile.open(fileobj=compressed,mode='w',format=tarfile.PAX_FORMAT) as tar:
    for item in [app,*sorted(app.rglob('*'))]:
     info=tar.gettarinfo(str(item),arcname=str(item.relative_to(work)))
     info.mtime=0;info.uid=0;info.gid=0;info.uname='';info.gname='';info.pax_headers={}
     if item.is_file():
      with item.open('rb') as contents_file:tar.addfile(info,contents_file)
     else:tar.addfile(info)
 (out/'manifest.json').write_text(json.dumps({'schema':1,'app':app.name,'minimum_macos':'14.0',
  'architecture':'arm64','target_executable':a.target_executable,'files':files,'archive':archive.name,'archive_sha256':sha(archive),
  'sources':{n:sha(HERE/n) for n in ['main.m','build.py']},'helper_inputs':{n:sha(helpers/n) for n in ['launch','registry-discovery.dylib']},
  'compiler_sha256':sha(Path(compiler)),'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
  'command':command,'target_app_modified':False},indent=2)+'\n')
 workspace.cleanup()
 print(archive)
if __name__=='__main__':main()
