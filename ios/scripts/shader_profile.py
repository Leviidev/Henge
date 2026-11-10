"""Protocol3 profile binding; protocol2 artifacts never acquire inferred flags."""
import base64,hashlib,json,re
DOMAIN='henge-shader-profile-v1\n'
CONTRACT='gl_half_range_v1'
TARGET='air64-apple-ios17.0.0'
def sha(b):return hashlib.sha256(b).hexdigest()
def digest(x):
 if not isinstance(x,str) or not re.fullmatch('[0-9a-f]{64}',x):raise ValueError('invalid digest')
 return x
def check_profile(p):
 if not isinstance(p,dict) or set(p)!={'schema','gl_clip_zero_to_one','vertex_functions','viewport_contract'}:raise ValueError('unknown profile shape')
 if type(p['schema'])is not int or p['schema']!=1 or type(p['gl_clip_zero_to_one'])is not bool:raise ValueError('invalid profile schema/flag')
 names=p['vertex_functions']
 if not isinstance(names,list)or len(names)>16 or any(not isinstance(n,str)or not 1<=len(n)<=1024 for n in names)or len(set(names))!=len(names):raise ValueError('invalid vertex function inventory')
 if p['gl_clip_zero_to_one']:
  if not names or p['viewport_contract']!=CONTRACT:raise ValueError('missing paired viewport contract')
 elif names or p['viewport_contract'] is not None:raise ValueError('nontransform profile contains vertex claims')
 return p
def binding(source,recipe,output,length,profile_sha):
 for x in [source,recipe,output,profile_sha]:digest(x)
 if type(length)is not int or not 4<=length<=32*1024*1024:raise ValueError('invalid output length')
 return sha((DOMAIN+'\n'.join([source,recipe,output,str(length),profile_sha])+'\n').encode('ascii'))
def envelope(profile,source,recipe,output):
 data=json.dumps(check_profile(profile),sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
 if len(data)>4096:raise ValueError('oversized profile')
 h=sha(data);return dict(schema=1,data=base64.b64encode(data).decode(),sha256=h,binding_sha256=binding(source,recipe,sha(output),len(output),h))
def verify_envelope(value,source,recipe,output):
 if not isinstance(value,dict)or set(value)!={'schema','data','sha256','binding_sha256'}or type(value['schema'])is not int or value['schema']!=1:raise ValueError('invalid profile envelope')
 data=base64.b64decode(value['data'],validate=True)
 if len(data)>4096 or sha(data)!=digest(value['sha256']):raise ValueError('profile digest mismatch')
 if value['binding_sha256']!=binding(source,recipe,sha(output),len(output),value['sha256']):raise ValueError('profile/source/recipe/output binding mismatch')
 return check_profile(json.loads(data))
def verify_receipt(receipt,source,recipe,output):
 if not isinstance(receipt,dict)or type(receipt.get('protocol'))is not int or receipt.get('protocol')!=3 or receipt.get('target')!=TARGET or receipt.get('status')!='ready' or receipt.get('sha256')!=source or receipt.get('recipe')!=recipe or receipt.get('output_sha256')!=sha(output)or type(receipt.get('length'))is not int or receipt.get('length')!=len(output):raise ValueError('invalid profiled receipt identity')
 return verify_envelope(receipt.get('transformation_profile'),source,recipe,output)
