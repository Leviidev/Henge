from pathlib import Path
import base64,hashlib,json,subprocess,sys,tempfile
R=Path(__file__).resolve().parents[1];sys.path.insert(0,str(R/'ios/scripts'));from shader_profile import envelope
source=(R/'devices/pvg_metal.m').read_text();methods=[]
for name in ['- (int)shaderRead:', '- (void)preflightReference:', '- (HvReplayReadiness)preflightCommand:']:
 start=source.rindex(name);end=source.index('\n}\n',start)+3;methods.append(source[start:end])
body=(R/'tests/pvg_preflight_body.m').read_text().replace('// ACTUAL_METHODS','\n'.join(methods));b=b'MTLB-authored-preflight';identity='a'*64;recipe='c'*64;config=dict(protocol=3,target='air64-apple-ios17.0.0',recipe=recipe)
receipt=dict(config,sha256=identity,status='ready',length=len(b),output_sha256=hashlib.sha256(b).hexdigest(),transformation_profile=envelope(dict(schema=1,gl_clip_zero_to_one=False,vertex_functions=[],viewport_contract=None),identity,recipe,b))
with tempfile.TemporaryDirectory()as t:
 p=Path(t);(p/'test.m').write_text(body);(p/'fixture.json').write_text(json.dumps(dict(source=identity,recipe=recipe,config=config,bytes=base64.b64encode(b).decode(),receipt=receipt)))
 subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wno-unused-function','-Wno-deprecated-declarations','-Wno-incompatible-pointer-types','-I'+str(R/'devices'),str(p/'test.m'),'-framework','Foundation','-framework','Metal','-o',str(p/'test')],check=True);subprocess.run([str(p/'test'),str(p/'fixture.json')],check=True)
