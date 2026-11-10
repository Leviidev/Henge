import json,os,subprocess,tempfile,unittest
from pathlib import Path
from gl_position_lower import lower,Unsupported
ROOT=Path(__file__).resolve().parent
FIXTURE='''target triple = "air64-apple-macosx14.6.0"
define { <2 x float>, <4 x float>, float } @"vertex with space"(<4 x float> %p, i1 %condition) {
entry:
  %a = insertvalue { <2 x float>, <4 x float>, float } undef, <2 x float> <float 0.25, float 0.75>, 0
  %b = insertvalue { <2 x float>, <4 x float>, float } %a, <4 x float> %p, 1
  %c = insertvalue { <2 x float>, <4 x float>, float } %b, float 2.0, 2
  br i1 %condition, label %yes, label %no
yes:
  ret { <2 x float>, <4 x float>, float } %c
no:
  ret { <2 x float>, <4 x float>, float } %c
}
!air.language_version = !{!0}
!air.vertex = !{!1}
!0 = !{!"OpenGL GLSL", i32 1, i32 0, i32 0}
!1 = !{{ <2 x float>, <4 x float>, float } (<4 x float>, i1)* @"vertex with space", !2, !6}
!2 = !{!3, !4, !5}
!3 = !{!"air.vertex_output", !"user(uv)"}
!4 = !{!"air.position", !"air.arg_type_name", !"float4"}
!5 = !{!"air.vertex_output", !"user(w)"}
!6 = !{}
'''
@unittest.skipUnless((ROOT/"gl-position-plan").is_file(), "build the optional LLVM planner with build_gl_position.py")
class Position(unittest.TestCase):
 def run_ir(self,text):
  with tempfile.TemporaryDirectory()as t:
   a=Path(t)/'in.ll';b=Path(t)/'out.ll';a.write_text(text);r=lower(a,b);return r,b.read_text()
 def test_metadata_slot_and_multiple_return_paths(self):
  r,s=self.run_ir(FIXTURE);self.assertTrue(r['profile']['gl_clip_zero_to_one']);self.assertEqual(r['plan']['functions'][0]['position_slot'],1);self.assertEqual(s.count(' = fadd float '),2);self.assertIn('user(uv)',s);self.assertIn('float 2.0, 2',s)
 def test_idempotent(self):
  _,s=self.run_ir(FIXTURE);r,t=self.run_ir(s);self.assertEqual(s,t);self.assertFalse(r['changed']);self.assertTrue(r['profile']['gl_clip_zero_to_one'])
 def test_non_gl_byte_exact(self):
  text=FIXTURE.replace('OpenGL GLSL','Metal');r,s=self.run_ir(text);self.assertEqual(text,s);self.assertFalse(r['profile']['gl_clip_zero_to_one'])
 def test_gl_fragment_byte_exact(self):
  text=FIXTURE.replace('!air.vertex =','!air.fragment =');r,s=self.run_ir(text);self.assertEqual(text,s);self.assertFalse(r['profile']['gl_clip_zero_to_one'])
 def test_missing_language_is_not_inferred_from_names(self):
  text=FIXTURE.replace('!air.language_version = !{!0}','');r,s=self.run_ir(text);self.assertEqual(text,s);self.assertFalse(r['profile']['gl_clip_zero_to_one'])
 def test_duplicate_position_rejected(self):
  with self.assertRaisesRegex(Unsupported,'multiple position'):self.run_ir(FIXTURE.replace('!"air.vertex_output", !"user(w)"','!"air.position"'))
 def test_output_layout_mismatch_rejected(self):
  with self.assertRaisesRegex(Unsupported,'does not match'):self.run_ir(FIXTURE.replace('!2 = !{!3, !4, !5}','!2 = !{!3, !4}'))
 def test_unknown_marker_rejected(self):
  t=FIXTURE.replace('i1 %condition) {','i1 %condition) "henge.gl_clip_zero_to_one"="2" {')
  with self.assertRaisesRegex(Unsupported,'marker version'):self.run_ir(t)
 @unittest.skipUnless(os.environ.get("HENGE_GL_VLC_VERTEX_IR"), "optional private VLC AIR corpus not distributed")
 def test_real_vlc_air_metadata(self):
  r,s=self.run_ir(Path(os.environ['HENGE_GL_VLC_VERTEX_IR']).read_text());f=r['plan']['functions'];self.assertEqual([(x['name'],x['position_slot'])for x in f],[('air.vertexFetchFunction',2)]);self.assertEqual(s.count(' = fadd float %henge_gl_clip'),1)
 def test_paired_depth_algebra_nonunit_w_reversed_ranges(self):
  for w in [.25,1,2,8]:
   for z_ndc in [-1,-.5,0,.5,1]:
    for near,far in [(0,1),(.2,.8),(.8,.2)]:
     z=z_ndc*w;raw=(near+far)/2;normalized=(z+w)/2
     self.assertAlmostEqual((2*raw-far)+(far-(2*raw-far))*normalized/w,near+(far-near)*(z_ndc+1)/2)
if __name__=='__main__':unittest.main(verbosity=2)
