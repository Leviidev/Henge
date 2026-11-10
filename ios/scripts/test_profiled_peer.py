import base64,hashlib,json,os,tempfile,unittest
from pathlib import Path
from shader_compiler_peer_profiled import Peer
from shader_companion_profiled import compile_request
from shader_profile import verify_receipt,envelope
ROOT=Path(__file__).resolve().parent
SOURCE=Path(os.environ['HENGE_GL_VLC_METALLIB'])if os.environ.get('HENGE_GL_VLC_METALLIB')else None
RECIPE='b'*64
@unittest.skipUnless(SOURCE is not None and (ROOT/"gl-position-plan").is_file(), "optional retained VLC fixture and LLVM planner are required; private assets are not distributed")
class PeerProfile(unittest.TestCase):
 def prepare(self,root):
  peer=Peer(root,RECIPE);data=SOURCE.read_bytes();digest=hashlib.sha256(data).hexdigest();(root/('sonoma-guestlib-'+digest+'.metallib')).write_bytes(data);request=dict(protocol=3,target='air64-apple-ios17.0.0',sha256=digest,recipe=RECIPE,owner=peer.owner,request='00000000-0000-4000-8000-000000000001');(peer.requests/(digest+'.json')).write_text(json.dumps(request));return peer,data,digest,request
 def test_complete_conversion_cache_publish_and_tamper(self):
  with tempfile.TemporaryDirectory()as t:
   root=Path(t);peer,data,digest,request=self.prepare(root)
   try:
    command=dict(request,source=base64.b64encode(data).decode());compiled=compile_request(command,root/'host-cache',RECIPE);out=compiled['output'];publication=dict(op='publish',sha256=digest,request=request['request'],output=base64.b64encode(out).decode(),output_sha256=hashlib.sha256(out).hexdigest(),transformation_profile=compiled['transformation_profile']);peer.publish(publication)
    receipt=json.loads((peer.cache/(digest+'.json')).read_text());profile=verify_receipt(receipt,digest,RECIPE,out);self.assertTrue(profile['gl_clip_zero_to_one']);self.assertEqual(profile['vertex_functions'],['air.vertexFetchFunction']);self.assertFalse(peer.handle(dict(op='poll'))['requests'])
    second=compile_request(command,root/'host-cache',RECIPE);self.assertEqual(second,compiled)
    # Tampered profile cannot suppress a new request merely because output bytes match.
    receipt['transformation_profile']['binding_sha256']='0'*64;(peer.cache/(digest+'.json')).write_text(json.dumps(receipt));self.assertEqual(len(peer.handle(dict(op='poll'))['requests']),1)
    report=dict(status='protocol3_conversion_publish_cache_and_invalid_profile_retry_verified',source_sha256=digest,output_sha256=hashlib.sha256(out).hexdigest(),profile=profile)
    self.assertEqual(report['profile']['vertex_functions'],['air.vertexFetchFunction'])
   finally:peer.close()
 def test_missing_profile_never_publishes_ready(self):
  with tempfile.TemporaryDirectory()as t:
   root=Path(t);peer,data,digest,request=self.prepare(root)
   try:
    with self.assertRaises(ValueError):peer.publish(dict(op='publish',sha256=digest,request=request['request'],output=base64.b64encode(data).decode(),output_sha256=digest))
    self.assertFalse((peer.cache/(digest+'.metallib')).exists());self.assertFalse((peer.cache/(digest+'.json')).exists())
   finally:peer.close()
if __name__=='__main__':unittest.main(verbosity=2)
