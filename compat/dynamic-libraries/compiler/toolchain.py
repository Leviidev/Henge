"""Portable tool discovery and process-group deadlines for offline AIR compilation."""
import os,shutil,signal,subprocess,threading,time
from pathlib import Path
LOCAL=threading.local()
def llvm_config():
 candidates=[os.environ.get('HENGE_LLVM_CONFIG'),shutil.which('llvm-config'),'/opt/homebrew/opt/llvm/bin/llvm-config','/usr/local/opt/llvm/bin/llvm-config']
 for p in candidates:
  if p and Path(p).is_file():return p
 raise RuntimeError('LLVM development tools are required; set HENGE_LLVM_CONFIG to llvm-config')
def llvm_tool(name):return str(Path(subprocess.check_output([llvm_config(),'--bindir'],text=True,timeout=5).strip())/name)
def close_tool():
 p=Path(os.environ.get('HENGE_DYNAMIC_BUILD',str(Path(__file__).resolve().parent.parent/'build')))/'close-air'
 if not p.is_file():raise RuntimeError('Build the package compiler helper first: python3 build.py')
 return str(p)
def compilation_deadline(seconds):LOCAL.deadline=time.monotonic()+seconds
def run(command,timeout=20):
 left=getattr(LOCAL,'deadline',time.monotonic()+timeout)-time.monotonic()
 if left<=0:raise TimeoutError('AIR dependency closure exceeded the45second compilation budget')
 process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try:out,err=process.communicate(timeout=min(timeout,left))
 except subprocess.TimeoutExpired:
  os.killpg(process.pid,signal.SIGKILL);process.communicate();raise TimeoutError('Compiler subprocess exceeded its deadline: '+str(command[0]))
 return subprocess.CompletedProcess(command,process.returncode,out,err)
def output(command):
 r=run(command)
 if r.returncode:raise RuntimeError(r.stderr or 'compiler tool failed')
 return r.stdout
