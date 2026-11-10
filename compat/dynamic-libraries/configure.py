#!/usr/bin/env python3
"""Write explicit guest configuration; optionally generate a new token file locally."""
import argparse,json,secrets
from pathlib import Path
ROOT=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--build-dir',type=Path,default=ROOT/'build');p.add_argument('--endpoint',required=True);p.add_argument('--guest-token-file',required=True);p.add_argument('--guest-cache-directory',default='~/Library/Caches/Henge/DynamicLibraries');p.add_argument('--output',type=Path,required=True);p.add_argument('--generate-token',type=Path);p.add_argument('--timeout-seconds',type=int,default=45);a=p.parse_args()
recipe=json.loads((a.build_dir/'recipe.json').read_text())['recipe_sha256']
if not 1<=a.timeout_seconds<=60:p.error('timeout must be1–60seconds')
if a.generate_token:
 with a.generate_token.open('x')as f:f.write(secrets.token_hex(32)+'\n')
 a.generate_token.chmod(0o600)
c=dict(schema=1,enabled=True,recipe_sha256=recipe,endpoint=a.endpoint,token_file=a.guest_token_file,cache_directory=a.guest_cache_directory,timeout_seconds=a.timeout_seconds)
with a.output.open('x')as f:f.write(json.dumps(c,indent=2)+'\n')
a.output.chmod(0o600);print(a.output)
