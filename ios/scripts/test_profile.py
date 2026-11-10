import base64,copy,json,subprocess,tempfile,unittest
from pathlib import Path
from shader_profile import *
ROOT=Path(__file__).resolve().parent
OUTPUT=b'MTLB'+b'unit-only-profile-bytes'*8
SOURCE='a'*64;RECIPE='b'*64
PROFILE=dict(schema=1,gl_clip_zero_to_one=True,vertex_functions=['air.vertexFetchFunction'],viewport_contract=CONTRACT)
def receipt(profile=PROFILE):return dict(protocol=3,target=TARGET,status='ready',sha256=SOURCE,recipe=RECIPE,output_sha256=sha(OUTPUT),length=len(OUTPUT),transformation_profile=envelope(profile,SOURCE,RECIPE,OUTPUT))
def fixtures():
 base=dict(id='valid_vertex',receipt=receipt(),output=base64.b64encode(OUTPUT).decode(),source=SOURCE,recipe=RECIPE,function_name='air.vertexFetchFunction',function_type=1,valid=True,attach=True,flag=True);cases=[base]
 for name,change in [('old_protocol',lambda r:r.update(protocol=2)),('fractional_protocol',lambda r:r.update(protocol=3.5)),('floating_integral_protocol',lambda r:r.update(protocol=3.0)),('fractional_length',lambda r:r.update(length=len(OUTPUT)+.5)),('boolean_schema',lambda r:r['transformation_profile'].update(schema=True)),('fractional_schema',lambda r:r['transformation_profile'].update(schema=1.5)),('missing_profile',lambda r:r.pop('transformation_profile')),('wrong_source',lambda r:r.update(sha256='c'*64)),('wrong_recipe',lambda r:r.update(recipe='c'*64)),('wrong_output',lambda r:r.update(output_sha256='c'*64)),('wrong_length',lambda r:r.update(length=len(OUTPUT)+1)),('bad_profile_digest',lambda r:r['transformation_profile'].update(sha256='c'*64)),('bad_binding',lambda r:r['transformation_profile'].update(binding_sha256='c'*64))]:
  c=copy.deepcopy(base);c.update(id=name,valid=False,attach=False,flag=False);change(c['receipt']);cases.append(c)
 c=copy.deepcopy(base);c.update(id='unlisted_vertex_rejected',function_name='other_vertex',attach=False,flag=False);cases.append(c)
 c=copy.deepcopy(base);c.update(id='listed_nonvertex_rejected',function_type=2,attach=False,flag=False);cases.append(c)
 c=copy.deepcopy(base);c.update(id='unrelated_fragment_unflagged',function_name='fragment',function_type=2,flag=False);cases.append(c)
 c=copy.deepcopy(base);c.update(id='honest_nonGL_profile',receipt=receipt(dict(schema=1,gl_clip_zero_to_one=False,vertex_functions=[],viewport_contract=None)),flag=False);cases.append(c)
 return cases
class Profile(unittest.TestCase):
 def test_tuple_binding(self):
  for c in fixtures():
   if c['valid']:verify_receipt(c['receipt'],c['source'],c['recipe'],OUTPUT)
   else:
    with self.assertRaises(ValueError):verify_receipt(c['receipt'],c['source'],c['recipe'],OUTPUT)
 def test_flag_tamper_without_rebinding_rejected(self):
  r=receipt();e=r['transformation_profile'];p=json.loads(base64.b64decode(e['data']));p.update(gl_clip_zero_to_one=False,vertex_functions=[],viewport_contract=None);e['data']=base64.b64encode(json.dumps(p).encode()).decode()
  with self.assertRaises(ValueError):verify_receipt(r,SOURCE,RECIPE,OUTPUT)
 def test_cross_language_host_validation(self):
  with tempfile.TemporaryDirectory(prefix='henge-profile-unit-')as temporary:
   folder=Path(temporary);path=folder/'fixtures.json';path.write_text(json.dumps(fixtures(),indent=2)+'\n');binary=folder/'profile-fixture';repo=ROOT.parents[1]
   subprocess.run(['xcrun','clang','-target','arm64-apple-macos14','-fobjc-arc','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations','-I'+str(repo/'devices'),str(repo/'tests/shader_profile_fixture.m'),'-framework','Foundation','-o',str(binary)],check=True)
   q=subprocess.run([str(binary),str(path)],capture_output=True,text=True);self.assertEqual(q.returncode,0,q.stdout+q.stderr)
 def test_host_profiled_selection_policy_without_GPU(self):
  with tempfile.TemporaryDirectory(prefix='henge-profile-selection-')as temporary:
   folder=Path(temporary);path=folder/'fixture.json';path.write_text(json.dumps(dict(bytes=base64.b64encode(OUTPUT).decode(),source=SOURCE,recipe=RECIPE,receipt=receipt())))
   binary=folder/'selection';repo=ROOT.parents[1]
   subprocess.run(['xcrun','clang','-target','arm64-apple-macos14','-fobjc-arc','-Wno-deprecated-declarations','-I'+str(repo/'devices'),str(repo/'tests/shader_profile_selection.m'),'-framework','Foundation','-o',str(binary)],check=True)
   q=subprocess.run([str(binary),str(path)],capture_output=True,text=True);self.assertEqual(q.returncode,0,q.stdout+q.stderr)
   result=json.loads(q.stdout);self.assertTrue(result['all_pass']);self.assertEqual(len(result['cases']),8)
if __name__=='__main__':unittest.main(verbosity=2)
