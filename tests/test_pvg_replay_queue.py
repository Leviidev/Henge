from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory()as t:
 exe=Path(t)/'queue'
 subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-I'+str(root/'devices'),str(root/'tests/pvg_replay_queue_control.m'),'-framework','Foundation','-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
