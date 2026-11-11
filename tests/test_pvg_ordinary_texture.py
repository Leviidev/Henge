#!/usr/bin/env python3
"""Build/run CPU-only ordinary texture decoder tests with ASan and UBSan."""
from pathlib import Path
import argparse
import os
import shlex
import subprocess
import tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[1])
parser.add_argument('--cc',default=os.environ.get('CC','cc'))
args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='henge-ordinary-texture-') as output:
    binary=Path(output)/'test'
    command=shlex.split(args.cc)+['-std=c11','-Wall','-Wextra','-Werror',
        '-fsanitize=address,undefined','-I'+str(args.source_root.resolve()/'devices'),
        str(Path(__file__).with_suffix('.c')),'-o',str(binary)]
    subprocess.run(command,check=True)
    subprocess.run([str(binary)],check=True)
