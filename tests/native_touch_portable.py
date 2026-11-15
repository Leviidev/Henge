"""Run PR32's transport/watchdog cases on Linux; full HTTP and Swift tests run on Mac CI."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'tests/test_native_touch.c').read_text()
a = s.index('static void http(')
b = s.index('int main(void)', a)
s = s[:a] + s[b:]
s = s[:s.index('    char directory[')] + '    puts("native touch transport: transitions, bounds, idle wait, wake, overflow and watchdog passed");\n}\n'
with tempfile.TemporaryDirectory() as d:
    c = Path(d) / 'touch.c'; c.write_text(s)
    exe = Path(d) / 'touch'
    subprocess.run(['cc', '-D_DEFAULT_SOURCE', '-std=c11', '-O1', '-g', '-fsanitize=address,undefined', '-pthread', '-I'+str(root/'host'), str(c), str(root/'host/native_touch.c'), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
