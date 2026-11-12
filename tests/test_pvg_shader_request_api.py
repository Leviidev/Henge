from pathlib import Path
import base64,hashlib,json,subprocess,sys,tempfile
r=Path(__file__).resolve().parents[1];sys.path.insert(0,str(r/'ios/scripts'))
from shader_profile import envelope
b=b'MTLB-authored-cache-policy';source='a'*64;recipe='c'*64
receipt=dict(protocol=3,target='air64-apple-ios17.0.0',recipe=recipe,sha256=source,status='ready',length=len(b),output_sha256=hashlib.sha256(b).hexdigest(),transformation_profile=envelope(dict(schema=1,gl_clip_zero_to_one=False,vertex_functions=[],viewport_contract=None),source,recipe,b))
with tempfile.TemporaryDirectory()as t:
 p=Path(t);(p/'fixture.json').write_text(json.dumps(dict(source=source,recipe=recipe,bytes=base64.b64encode(b).decode(),receipt=receipt)))
 subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wno-deprecated-declarations','-Wno-incompatible-pointer-types','-I'+str(r/'devices'),str(r/'tests/pvg_shader_request_api.m'),'-framework','Foundation','-framework','Metal','-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe'),str(p/'fixture.json')],check=True)
