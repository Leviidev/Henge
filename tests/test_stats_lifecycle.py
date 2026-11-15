#!/usr/bin/env python3
"""Exercise production reporting on recreated CPU0 threads, with deep scans off/on."""
import os
from pathlib import Path
import re
import subprocess

Path('build').mkdir(exist_ok=True)
for deep in ('0', '1'):
    env = {**os.environ, 'HV_STATS': '1', 'HENGE_TEST_STATS': '1', 'HV_STATS_HASH': deep}
    result = subprocess.run(['build/test_vm_lifecycle'], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    output = result.stdout
    Path(f'build/stats-lifecycle-{deep}.log').write_text(output)
    if result.returncode:
        print(output)
        raise SystemExit(result.returncode)
    per_cpu = re.findall(r'vcpu-work: cpu=(\d+) generation=(\d+) user_us=(\d+) system_us=(\d+)', output)
    assert len([x for x in per_cpu if x[0] == '0']) >= 2, 'missing real CPU0 accounting across Continue'
    assert len({x[1] for x in per_cpu}) >= 2, 'thread accounting lacks lifecycle generations'
    percentages = [int(n) for n in re.findall(r'cpu thread ran (-?\d+)%', output)]
    assert len(percentages) >= 2, ('no actual CPU0 report before/after Continue', percentages)
    assert all(0 <= n <= 105 for n in percentages), percentages
    assert not re.search(r'(?:nan|inf)(?:%|/s)', output, flags=re.I), 'nonfinite statistics'
    rates = re.findall(r'translated ([\d.]+)/s', output)
    assert rates and all(float(n) < 1e9 for n in rates), 'counter history crossed a machine/run boundary'
    assert ('block hash:' in output) == (deep == '1'), 'deep hash scan activation mismatch'
    print(f'PASS native stats: deep={deep}, {len(percentages)} CPU0 reports, range={min(percentages)}..{max(percentages)}%; pause/continue/reboot lifecycle passed')
