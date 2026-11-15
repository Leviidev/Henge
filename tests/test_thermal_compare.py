import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parents[1]/'tools/thermal/compare_runs.py';s=importlib.util.spec_from_file_location('compare',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
a={'conditions':{k:'same' for k in m.CONDITIONS}}
assert m.compare(a,a)['controlled_comparison']
b={'conditions':{**a['conditions'],'start_thermal':'hot'}}
assert not m.compare(a,b)['controlled_comparison']
assert not m.compare({'conditions':{}},a)['controlled_comparison']
l=m.parse_log('[prev] panic(cpu 0): old\n[10ms][session] screen 2752x2064 retina true\nframe-presented: average_fps=60\n')
assert not l['panic'] and l['game_average_fps'] is None and l['energy_per_displayed_frame_joules'] is None
assert m.parse_log('hengevm: guest reported a panic')['panic']
print('thermal comparisons: matched-condition gate, heat mismatch rejection, missing fields, previous panic exclusion and unknown physical metrics passed')
