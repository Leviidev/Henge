"""Production selector: duplicate version numbers and model-only runtimes."""
import ast
from pathlib import Path
root=Path(__file__).resolve().parents[1]
module=ast.parse((root/'tools/preview_gamepad.py').read_text())
function=next(n for n in module.body if isinstance(n,ast.FunctionDef) and n.name=='simulator_pairs')
namespace={};exec(compile(ast.Module(body=[function],type_ignores=[]),'<production simulator selector>','exec'),namespace)
select=namespace['simulator_pairs']
duo=dict(name='iPhone Duo',identifier='duo')
m4=dict(name='iPad Pro 13-inch (M4) (16GB)',identifier='m4')
def runtime(identifier,version,types):return dict(name='iOS '+version,identifier=identifier,version=version,isAvailable=True,supportedDeviceTypes=types)
meta=dict(devicetypes=[duo,m4],runtimes=[runtime('standard','27.2',[m4]),runtime('duo-only','27.2',[duo]),runtime('older','27.1',[duo])])
assert [(r['identifier'],d['identifier']) for r,d in select(meta,'duo-unfolded')]==[('duo-only','duo'),('older','duo'),('standard','m4')]
assert select(meta,'m4-13')[0][0]['identifier']=='standard'
assert all(d['identifier']=='m4' for _,d in select(meta,'duo-unfolded',True))
assert select(meta,'duo-unfolded',True)[0][0]['identifier']=='standard'
meta['runtimes'][1]['isAvailable']=False
assert select(meta,'duo-unfolded')[0][0]['identifier']=='older'
meta['devicetypes']=[m4]
assert select(meta,'duo-unfolded')[0][1]['identifier']=='m4'
print('Simulator selection: dedicated Duo runtime before fallback, latest compatible M4, unavailable runtime and missing-model fallback passed')
