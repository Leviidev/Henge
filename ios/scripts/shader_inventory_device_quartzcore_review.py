#!/usr/bin/env python3
"""Review the full QuartzCore archive's authored two-function consumer."""
import argparse
from collections import Counter
import json
from pathlib import Path
from shader_inventory_device_historical_review import expected_bgra,packed_inputs,sha


def review(manifest_bytes,report,raw_directory):
    m=json.loads(manifest_bytes);issues=[]
    def check(ok,why):
        if not ok:issues.append(why)
    check(report.get('status')=='completed_requires_review','run incomplete')
    check(report.get('manifest_sha256')==sha(manifest_bytes),'manifest binding')
    check(report.get('exact_historical_descriptor_verified') is False,'historical descriptor claim')
    for field in ['library_loaded','vertex_specialized','fragment_specialized','pipeline_created']:check(report.get(field),field+' failed')
    check(report.get('library_function_count')==150,'full archive function count')
    check(m['vertex']['function']=='fixed_vert_lph_spc' and m['fragment']['function']=='fixed_frag_lph_cpf','base function identity')
    expected={'color0':80,'samples':1,'vertex_buffer':1,'stride':48,'position_attribute':0,'position_offset':0,'color_attribute':3,'color_offset':32,'hardware_blending':False}
    check(report.get('descriptor')==expected,'authored vertex/render descriptor')
    specs={s['id']:s for s in m['cases']};rows=report.get('cases',[])
    check(Counter(c.get('id') for c in rows)==Counter(specs.keys()),'case matrix missing/duplicated')
    for c in rows:
        spec=specs.get(c.get('id'))
        if spec is None:continue
        pixel=expected_bgra(spec);wanted=bytes(pixel)*256;path=raw_directory/(spec['id']+'.bgra8')
        check(pixel==spec['expected_bgra8'],'manifest CPU oracle disagreement')
        check(path.is_file() and path.read_bytes()==wanted,spec['id']+': raw pixels')
        check(c.get('dispatch_completed') and c.get('draw_encoded') and c.get('pixels_checked')==256 and c.get('mismatched_bytes')==0 and c.get('actual_sha256')==sha(wanted),spec['id']+': execution/result binding')
        check(all(c.get(k)==v for k,v in packed_inputs(spec).items()),spec['id']+': input buffer bytes')
    return {'status':'two_shipped_base_functions_pass_authored_consumer' if not issues else 'failed_or_incomplete','issues':issues,'pixels_checked':768 if not issues else 0,'library_sha256':m['library']['sha256'],'manifest_sha256':sha(manifest_bytes),'scope':'Full 150-module library, two base functions specialized with captured constants; authored descriptor/resources. Neither all-function execution nor recovered historical descriptor.'}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--report',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();r=review(a.manifest.read_bytes(),json.loads(a.report.read_text()),a.report.parent);a.output.write_text(json.dumps(r,indent=2)+'\n');print(r['status']);raise SystemExit(bool(r['issues']))
if __name__=='__main__':main()
