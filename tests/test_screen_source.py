"""Keep the emergency runtime shader fallback identical to the compiled source."""
import ast
import re
from pathlib import Path
root = Path(__file__).resolve().parents[1]
header = (root / 'devices/pvg_screen.h').read_text().split('static id<MTLRenderPipelineState>')[0]
source = ''.join(ast.literal_eval(x) for x in re.findall(r'@?("(?:[^"\\]|\\.)*")', header))
assert source == (root / 'devices/pvg_screen.metal').read_text()
print('native Metal compiled/fallback shader source parity passed')
