import hashlib,json,os,sys,tempfile,time,unittest,uuid
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]/'ios/scripts'
sys.path.insert(0,str(ROOT))
from shader_compile_runtime import run_converter
from shader_compiler_peer_profiled import Peer,write_json

class DeadlineTests(unittest.TestCase):
 def case(self,source,budget):
  with tempfile.TemporaryDirectory()as t:
   root=Path(t);p=root/'child.py';p.write_text(source);r=root/'stage.json'
   result=run_converter([sys.executable,str(p)],r,budget)
   return result,json.loads(r.read_text())
 def test_combined_stages_fit_one_budget(self):
  result,receipt=self.case("import sys\nsys.path.insert(0,"+repr(str(ROOT))+")\nfrom shader_compile_runtime import run_tool\nfor stage in ['one','two']:run_tool([sys.executable,'-c','import time;time.sleep(.08)'],stage=stage,check=True)\n",1)
  self.assertEqual(receipt['stage'],'two');self.assertEqual(receipt['state'],'finished')
 def test_combined_deadline_not_reset_per_stage(self):
  started=time.monotonic()
  with self.assertRaisesRegex(TimeoutError,'two'):
   self.case("import sys\nsys.path.insert(0,"+repr(str(ROOT))+")\nfrom shader_compile_runtime import run_tool\nfor stage in ['one','two']:run_tool([sys.executable,'-c','import time;time.sleep(.15)'],stage=stage,check=True)\n",.28)
  self.assertLess(time.monotonic()-started,1.5)
 def test_outer_guard_reaps_tool_descendant(self):
  with tempfile.TemporaryDirectory()as t:
   p=Path(t);marker=p/'orphan';child=p/'child.py'
   child.write_text("import subprocess,sys,time\nsubprocess.Popen([sys.executable,'-c',"+repr("import time;from pathlib import Path;time.sleep(.5);Path("+repr(str(marker))+").write_text('alive')")+"])\ntime.sleep(5)\n")
   with self.assertRaises(TimeoutError):run_converter([sys.executable,str(child)],p/'stage.json',.2)
   time.sleep(.55);self.assertFalse(marker.exists())
 def test_nonzero_is_not_timeout(self):
  with self.assertRaisesRegex(ValueError,'unsupported'):
   self.case("import sys;sys.stderr.write('unsupported');sys.exit(2)",1)
 def test_stale_stage_does_not_poison_next_attempt(self):
  with tempfile.TemporaryDirectory()as t:
   p=Path(t)/'stage.json';p.write_text('{"state":"timeout","stage":"old"}')
   run_converter([sys.executable,'-c','pass'],p,1)
   self.assertEqual(json.loads(p.read_text())['stage'],'startup')

class PeerTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.peer=Peer(self.root,'a'*64);self.source=b'MTLBauthored';self.sha=hashlib.sha256(self.source).hexdigest();self.req=dict(self.peer.config,owner=self.peer.owner,sha256=self.sha,request=str(uuid.uuid4()))
  write_json(self.peer.requests/(self.sha+'.json'),self.req);(self.root/('sonoma-guestlib-'+self.sha+'.metallib')).write_bytes(self.source)
 def tearDown(self):self.peer.close();self.temp.cleanup()
 def poll(self,skip=[]):return self.peer.handle(dict(op='poll',skip=skip,slots=2))['requests']
 def publish(self,**kw):return self.peer.publish(dict(sha256=self.sha,request=self.req['request'],error='authored',**kw))
 def test_pending_coalesced_by_dispatcher_skip(self):
  self.assertEqual(len(self.poll()),1);self.assertEqual(self.poll([self.sha]),[])
 def test_transient_one_retry_after_backoff(self):
  with patch('shader_compiler_peer_profiled.time.time',return_value=100):self.publish(retryable=True);self.assertEqual(self.poll(),[])
  with patch('shader_compiler_peer_profiled.time.time',return_value=103):
   self.assertEqual(len(self.poll()),1);self.publish(retryable=True)
  with patch('shader_compiler_peer_profiled.time.time',return_value=1000):self.assertEqual(self.poll(),[])
  receipt=json.loads((self.peer.cache/(self.sha+'.json')).read_text());self.assertEqual(receipt['attempt'],2);self.assertFalse(receipt['retryable'])
 def test_deterministic_failure_not_retried(self):
  self.publish(retryable=False)
  with patch('shader_compiler_peer_profiled.time.time',return_value=1e12):self.assertEqual(self.poll(),[])
 def test_stale_publication_rejected(self):
  with self.assertRaisesRegex(ValueError,'superseded'):self.peer.publish(dict(sha256=self.sha,request=str(uuid.uuid4()),error='stale'))
  self.assertFalse((self.peer.cache/(self.sha+'.json')).exists())
 def test_wrong_owner_not_accepted(self):
  self.req['owner']=str(uuid.uuid4());write_json(self.peer.requests/(self.sha+'.json'),self.req);self.assertEqual(self.poll(),[])

if __name__=='__main__':unittest.main(verbosity=2)
