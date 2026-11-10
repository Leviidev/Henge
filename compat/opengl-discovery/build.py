#!/usr/bin/env python3
"""Build source-only, process-scoped CGL discovery and authored controls."""
import argparse,hashlib,json,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
 compiler=subprocess.check_output(['xcrun','--find','clang'],text=True).strip()
 commands=[]
 for name,extra,frameworks in [('registry_discovery',['-dynamiclib'],['Foundation','IOKit']),('draw_probe',[],['Foundation','Metal','OpenGL']),('draw_matrix',[],['Foundation','OpenGL'])]:
  target=out/('registry-discovery.dylib'if name=='registry_discovery'else name)
  command=[compiler,'-arch','arm64','-mmacosx-version-min=14.0','-O2','-fobjc-arc','-Wall','-Wextra','-Wno-deprecated-declarations',*extra,str(HERE/(name+'.m')),'-o',str(target)]+[v for framework in frameworks for v in ['-framework',framework]]
  with(out/(name+'.build.log')).open('w')as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
  subprocess.run(['codesign','--force','--sign','-',str(target)],check=True,capture_output=True);commands.append(command)
 (out/'manifest.json').write_text(json.dumps({'schema':1,'minimum_macos':'14.0','architecture':'arm64','sources':{n.name:sha(n)for n in HERE.glob('*.m')},'outputs':{n:sha(out/n)for n in ['registry-discovery.dylib','draw_probe','draw_matrix']},'compiler_sha256':sha(Path(compiler)),'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),'commands':commands},indent=2)+'\n')
if __name__=='__main__':main()
