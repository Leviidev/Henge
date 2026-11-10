from pathlib import Path
import hashlib,json,subprocess,os
from toolchain import llvm_config
ROOT=Path(__file__).resolve().parent.parent
NAMES=['guest/adapter.m','guest/transport.m','guest/runtime.m','compiler/closure.py','compiler/close_air.cpp','compiler/lower_closures.py','compiler/compile_requests.py','compiler/toolchain.py','compiler/metallib_catalog.py','compiler/recipe.py']
def sha(b):return hashlib.sha256(b).hexdigest()
def build_dir():return Path(os.environ.get('HENGE_DYNAMIC_BUILD',str(ROOT/'build')))
def tools():
 result={}
 for name,cmd in [('metal',['xcrun','--sdk','macosx','metal','--version']),('air_lld',['xcrun','--sdk','macosx','air-lld','--version']),('llvm',[llvm_config(),'--version'])]:
  q=subprocess.run(cmd,capture_output=True,text=True,check=True,timeout=10);result[name]=(q.stdout+q.stderr).strip()
 # The Metal toolchain's ephemeral mount path is operational provenance, not compiler identity.
 result['metal']='\n'.join(x for x in result['metal'].splitlines() if not x.startswith('InstalledDir:'))
 return result

def prepare(native_test=False):
 obj=dict(schema=1,policy='henge_stateless_compute_dynamic_1',source_sha256={n:sha((ROOT/n).read_bytes())for n in NAMES},tools=tools(),target='preserve_AIR_profile_and_platform',native_test_build=native_test,limits={'modules':64,'dependencies':16,'decoded_bytes':16*1024*1024,'request_bytes':24*1024*1024,'compiler_seconds':45})
 key=sha(json.dumps(obj,sort_keys=True,separators=(',',':')).encode());build_dir().mkdir(parents=True,exist_ok=True);(build_dir()/'recipe.json').write_text(json.dumps(dict(recipe_sha256=key,recipe=obj),indent=2)+'\n');return key

def verify():
 r=json.loads((build_dir()/'recipe.json').read_text());assert sha(json.dumps(r['recipe'],sort_keys=True,separators=(',',':')).encode())==r['recipe_sha256'],'recipe content mismatch'
 for n,h in r['recipe']['source_sha256'].items():assert sha((ROOT/n).read_bytes())==h,'compiler source changed; rebuild package: '+n
 assert tools()==r['recipe']['tools'],'compiler toolchain changed; rebuild package'
 return r['recipe_sha256']
