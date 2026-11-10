#!/usr/bin/env python3
"""Pin exact historical shader pair; authored oracle descriptor remains explicit."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from catalog_metallibs import inspect_metallib


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('inventory_root',type=Path);a=p.parse_args();root=a.inventory_root.resolve();out=root/'historical-6964-01';out.mkdir(exist_ok=True);vertex='e61ab240a95f18177c675d56f95153289e06ae85b9319eedb14535174795b366';fragment='69640e587e671fb4e39957cbba5202e30c3c742f38d21aea4939a5b07fc09925';cases=[{'id':'swap_red_to_green','clear_rgba':[1,0,0,1],'coverage':1,'matrix_columns':[[0,1,0,0],[1,0,0,0],[0,0,1,0],[0,0,0,1],[0,0,0,0]],'expected_bgra8':[0,255,0,255]},{'id':'swap_green_to_red','clear_rgba':[0,1,0,1],'coverage':1,'matrix_columns':[[0,1,0,0],[1,0,0,0],[0,0,1,0],[0,0,0,1],[0,0,0,0]],'expected_bgra8':[0,0,255,255]},{'id':'blue_bias_half_coverage','clear_rgba':[1,0,0,1],'coverage':0.5,'matrix_columns':[[0,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,1],[0,0,1,0]],'expected_bgra8':[128,0,128,255]}]
    for folder,kind in [('NativeResources','guest'),('AuditAssets','ios')]:
        assets=out/folder;assets.mkdir(exist_ok=True);m={'schema':1,'kit':'historical-6964-01','descriptor_scope':'authored contract, not recovered historical descriptor','cases':cases,'source_fragment_id':fragment,'source_vertex_id':vertex,'platform_asset_set':kind}
        for role,sid,fn in [('vertex',vertex,'air.vertexFetchFunction'),('fragment',fragment,'BvcmA2Xhfc')]:
            source=(root/'profile-compute-audit/sync/guest'/('sonoma-guestlib-'+sid+'.metallib') if kind=='guest' else root/'plane-render-followup/AuditData'/('sonoma-ioslib-'+sid+'.metallib'));r=inspect_metallib(source.read_bytes());assert not r['malformed_records'] and not r['integrity_mismatches'] and [f['name'] for f in r['functions']]==[fn];assert r['header']['target_os']==('macOS' if kind=='guest' else 'iOS');shutil.copyfile(source,assets/(role+'.metallib'));m[role]={'file':role+'.metallib','sha256':sha(source),'source_sha256':sid,'retained_path':str(source),'function':fn,'target':r['header']}
        (assets/'historical-render-jobs.json').write_text(json.dumps(m,indent=2)+'\n')
    base=root/'inventory-device-03';project=out/'HengeShaderAudit.xcodeproj';project.mkdir(exist_ok=True);s=(base/'HengeShaderAudit.xcodeproj/project.pbxproj').read_text().replace('shader_inventory_device_runner.m','shader_inventory_device_historical_render.m');(project/'project.pbxproj').write_text(s);shutil.copyfile(base/'Info.plist',out/'Info.plist');print(out)


if __name__=='__main__':main()
