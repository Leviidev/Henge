#!/usr/bin/env python3
"""Compare controlled trials. Unknown physical measurements stay null; no FPS from coarse frame counters."""
import argparse,json,re
from pathlib import Path
CONDITIONS=('device','os','guest_os','workload','scene','game_settings','resolution','hidpi','refresh_hz','cpus','guest_ram_mb','jit_mb','brightness','charging','case','orientation','ambient_c','start_thermal','warmup_seconds','measurement_seconds','instrumentation')
def parse_log(text):
 def last(pat):
  rows=re.findall(pat,text,re.M);return rows[-1] if rows else None
 result={'custom_source':last(r'\[boot\] custom source: ([0-9a-f]+)'),
  'screen':last(r'\[session\] screen (\d+x\d+) retina (true|false)'),
  'jit_cache':last(r'jit-cache:.*used=([\d.]+)MiB.*full_flushes=(\d+)'),
  'frame_presented':last(r'^frame-presented: (.*)$'),
  'gpu_execution':last(r'^hengevm: gpu-execution: (.*)$'),
  'task_wakeups':last(r'^task-wakeups: (.*)$'),
  'thermal_transitions':re.findall(r'\[([\d.]+)ms\]\[session\] thermal state: (.*)',text),
  'panic':bool(re.search(r'^(?!.*\[prev\]).*(?:guest reported a panic|panic\(cpu|unmapped read:)',text,re.M))}
 # Neither sampled code counters nor a sum of overlapping GPU times is GPU utilization or energy.
 result.update(game_average_fps=None,game_low1_fps=None,gpu_active_utilization=None,cpu_gpu_power_watts=None,energy_per_displayed_frame_joules=None)
 return result

def compare(before,after):
 missing=[k for k in CONDITIONS if k not in before['conditions'] or k not in after['conditions']]
 different=[k for k in CONDITIONS if k not in missing and before['conditions'][k]!=after['conditions'][k]]
 return {'controlled_comparison':not missing and not different,'missing_conditions':missing,'different_conditions':different,
  'before':before,'after':after,'conclusion':'No efficiency or non-regression conclusion without matched conditions, repeated trials and actual measured outcomes.'}
def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('before',type=Path);ap.add_argument('after',type=Path);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
 runs=[]
 for p in (a.before,a.after):
  data=json.loads(p.read_text());data['log_summary']=parse_log((p.parent/data['log']).read_text(errors='replace'));runs.append(data)
 out=compare(*runs);a.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps({'controlled_comparison':out['controlled_comparison'],'missing':out['missing_conditions'],'different':out['different_conditions']}));return 0 if out['controlled_comparison'] else 2
if __name__=='__main__':raise SystemExit(main())
