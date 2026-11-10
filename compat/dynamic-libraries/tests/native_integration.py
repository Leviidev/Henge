#!/usr/bin/env python3
"""Native-only opt-in interposition/transport controls; no guest/device endpoints."""
import argparse,hashlib,json,os,secrets,subprocess,sys,threading,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent

def main():
 p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--controls',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();build=a.build.resolve();controls=a.controls.resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True);os.environ['HENGE_DYNAMIC_BUILD']=str(build);sys.path.insert(0,str(ROOT/'compiler'));from dynamic_peer_http import server
 token=secrets.token_hex(24);tf=out/'token';tf.write_text(token);tf.chmod(0o600);http,pool=server('127.0.0.1',0,token,out/'host-exchange',out/'compiler-work');thread=threading.Thread(target=http.serve_forever);thread.start();server_running=True
 config=dict(schema=1,enabled=True,recipe_sha256=json.loads((build/'recipe.json').read_text())['recipe_sha256'],endpoint='http://127.0.0.1:'+str(http.server_port),token_file=str(tf),cache_directory=str(out/'cache'),timeout_seconds=30);cp=out/'config.json';cp.write_text(json.dumps(config));cp.chmod(0o600);env=dict(os.environ,HENGE_DYNAMIC_TEST_DEVICE='1');results=[]
 try:
  for exe,args in [('dynamic-controls',[str(controls/'AuditAssets'),str(out/'matrix'),'--inventory-stage','controls']),('async-lifetime',[str(out/'async')]),('dependency-snapshot',[str(out/'snapshot')])]:
   cmd=['bash',str(build/'guest/run.sh'),'--config',str(cp),'--',str(controls/exe),*args];start=time.time();q=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=120);(out/(exe+'.log')).write_text(q.stdout+q.stderr);results.append(dict(executable=exe,returncode=q.returncode,seconds=time.time()-start));assert q.returncode==0,(exe,q.returncode,q.stdout,q.stderr)
  latest=json.loads((out/'matrix/inventory-latest.json').read_text())['run_id'];matrix=json.loads((out/'matrix'/latest/'inventory-report.json').read_text());assert matrix['packed_control']['all_specializations_exact'];assert all(c['execution']['readback_exact']for c in matrix['dynamic_control']['cases'][1:]);async_report=json.loads((out/'async/async-report.json').read_text());assert not any(async_report[n]for n in ['library_alive_after_callback','function_alive_after_callback','dynamic_alive_after_callback']);snapshot=json.loads((out/'snapshot/snapshot-report.json').read_text());assert snapshot['all_exact']
  assert len(list((out/'host-exchange/requests').glob('*.json')))==6
  assert not async_report['supports_render_dynamic']
  http.shutdown();thread.join(timeout=5);http.server_close();pool.shutdown(wait=True);server_running=False
  # Same application inputs and immutable closure identity work with compiler offline.
  cmd=['bash',str(build/'guest/run.sh'),'--config',str(cp),'--',str(controls/'async-lifetime'),str(out/'async')]
  q=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=45);(out/'async-offline.log').write_text(q.stdout+q.stderr);assert q.returncode==0,('offline',q.stdout,q.stderr)
  summary=dict(offline_async_cached=True,status='native_injected_package_cold_sync_async_snapshot_exact',cases=results,source_changes_to_controls_for_adapter_activation=False,source_callbacks=async_report['source_callbacks'],pipeline_callbacks=async_report['pipeline_callbacks'],directory=str(out),requests=len(list((out/'host-exchange/requests').glob('*.json'))));(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))
 finally:
  if server_running:http.shutdown();thread.join(timeout=5);http.server_close();pool.shutdown(wait=True)
  tf.unlink()
if __name__=='__main__':main()
