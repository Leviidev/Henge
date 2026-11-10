"""One conversion deadline and bounded stage telemetry; no renderer scheduling."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

DEFAULT_BUDGET = 30.0

def stage_record(stage, state, started, **extra):
    path = os.environ.get('HENGE_SHADER_STAGE_RECEIPT')
    if not path:
        return
    value = dict(stage=stage, state=state, elapsed_seconds=time.monotonic()-started, **extra)
    target = Path(path)
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, sort_keys=True)+'\n')
    os.replace(temporary, target)

def run_tool(command, *, stage, **kwargs):
    """Child tools share the parent's monotonic deadline, not N independent budgets."""
    started = time.monotonic()
    deadline = float(os.environ.get('HENGE_SHADER_DEADLINE', started+DEFAULT_BUDGET))
    remaining = deadline-started
    stage_record(stage, 'running', started)
    if remaining <= 0:
        stage_record(stage, 'timeout', started)
        raise TimeoutError('conversion deadline before '+stage)
    try:
        result = subprocess.run(command, timeout=remaining, **kwargs)
    except subprocess.TimeoutExpired as error:
        stage_record(stage, 'timeout', started)
        raise TimeoutError('conversion deadline in '+stage) from error
    except subprocess.CalledProcessError as error:
        stage_record(stage, 'failed', started, returncode=error.returncode)
        raise
    stage_record(stage, 'finished', started, returncode=result.returncode)
    return result

def run_converter(command, receipt, budget=DEFAULT_BUDGET):
    """Own the entire process group; always reap descendants on failure/timeout."""
    if not 0 < budget <= 120:
        raise ValueError('conversion budget must be >0 and <=120 seconds')
    started = time.monotonic()
    env = os.environ.copy()
    env.update(HENGE_SHADER_DEADLINE=str(started+budget), HENGE_SHADER_STAGE_RECEIPT=str(receipt))
    Path(receipt).write_text(json.dumps(dict(stage='startup',state='running',elapsed_seconds=0))+'\n')
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, env=env)
    timed_out = False
    try:
        _, errors = process.communicate(timeout=max(0.01, started+budget-time.monotonic()))
    except subprocess.TimeoutExpired:
        timed_out = True
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        _, errors = process.communicate()
    finally:
        if process.returncode:
            # A tool killed by an inner deadline may have forked children.
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
    stage = {}
    try: stage = json.loads(Path(receipt).read_text())
    except (OSError, ValueError): pass
    if timed_out or stage.get('state') == 'timeout':
        raise TimeoutError('conversion budget exhausted in '+str(stage.get('stage','startup')))
    if process.returncode:
        raise ValueError(errors.decode(errors='replace')[-2048:])
    return dict(elapsed_seconds=time.monotonic()-started, last_stage=stage)
