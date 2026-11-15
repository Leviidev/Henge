#!/usr/bin/env python3
"""Native source microbenchmark, not game FPS or power. Reference is pristine Henge 0.2."""
import argparse,json,statistics,subprocess
from pathlib import Path
ap=argparse.ArgumentParser();ap.add_argument('--reference',type=Path,required=True);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
r=Path(__file__).resolve().parents[2];build=r/'build/thermal';build.mkdir(parents=True,exist_ok=True)
variants=[('release_0_2',a.reference,False),('candidate_local_ppi',r,False),('candidate_paired',r,True)]
executables={};results={}
for name,src,paired in variants:
 s=(src/'devices/gicv3.c').read_text();needle='static int hppi(HvGic *g, int c, int masked) {'
 assert needle in s;s=s.replace(needle,needle+'\n    arbitrations++;',1)
 p=build/(name+'.c');p.write_text(s)
 exe=build/name
 cmd=['xcrun','--sdk','macosx','clang','-std=c11','-Wall','-Wextra','-Werror','-O2','-pthread','-I'+str(src/'core'),'-I'+str(src/'devices'),'-I'+str(src/'host'),'-DGIC_SOURCE="'+str(p)+'"']
 if paired:cmd+=['-DPAIRED=1']
 subprocess.run(cmd+[str(r/'tools/thermal/bench_gic.c'),'-o',str(exe)],check=True)
 executables[name]=exe;results[name]=[]
# Alternate ordering to reduce systematic first/last-run bias; still not a device game benchmark.
for rep in range(7):
 names=list(executables)
 if rep%2:names.reverse()
 for name in names:results[name].append(json.loads(subprocess.check_output([str(executables[name])],text=True)))
summary={name:{'median_elapsed_ms':statistics.median(x['elapsed_ms'] for x in rows),'arbitrations':rows[0]['arbitrations'],'runs':rows} for name,rows in results.items()}
assert all(x['irq_final']==1 for rows in results.values() for x in rows)
assert summary['candidate_paired']['arbitrations']<summary['release_0_2']['arbitrations']
out={'kind':'native GIC microbenchmark','power_measured':False,'game_fps_measured':False,'runner_arch':subprocess.check_output(['uname','-m'],text=True).strip(),'results':summary}
a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps({k:{x:y for x,y in v.items() if x!='runs'} for k,v in summary.items()},indent=2))
