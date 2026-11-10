#!/usr/bin/env python3
"""Validate bounded CGL probe and compare five authored draw outputs."""
import argparse,hashlib,json
from pathlib import Path
CASES=['texture_nearest','indexed_restart','blend_scissor','depth_reject_far','framebuffer_blit']
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--probe',type=Path,required=True);p.add_argument('--matrix',type=Path,required=True);p.add_argument('--reference',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--require-paravirtual',action='store_true');a=p.parse_args()
 probe=json.loads(a.probe.read_text());assert probe['phase']=='finished'and probe['context_created']and probe['accelerated']==1
 assert probe['clear_rgba']==[64,128,191,255]and probe['clear_get_tex_image']==[64,128,191,255]and probe['triangle_rgba']==[255,0,0,255]
 assert probe['gl_error']==probe['triangle_error']==0 and probe['vertex_compile']==probe['fragment_compile']==probe['program_linked']==1
 matrix=json.loads((a.matrix/'report.json').read_text());reference=json.loads((a.reference/'report.json').read_text())
 for report in [matrix,reference]:assert report['accelerated']==1 and report['width']==65 and report['height']==49 and [x['name']for x in report['cases']]==CASES and all(x['gl_error']==0 for x in report['cases'])
 if a.require_paravirtual:assert 'Paravirtual'in probe['gl_renderer']and 'Paravirtual'in matrix['renderer']
 cases={}
 for name in CASES:
  observed=(a.matrix/(name+'.rgba')).read_bytes();expected=(a.reference/(name+'.rgba')).read_bytes();assert observed==expected and len(observed)==65*49*4
  cases[name]={'bytes':len(observed),'sha256':hashlib.sha256(observed).hexdigest(),'exact':True}
 with a.output.open('x')as f:json.dump({'passed':True,'renderer':matrix['renderer'],'version':matrix['version'],'paravirtual_required':a.require_paravirtual,'cases':cases,'scope':'Authored bounded draw/readback controls; not all OpenGL applications or GPU features.'},f,indent=2)
if __name__=='__main__':main()
