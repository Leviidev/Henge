#!/usr/bin/env python3
"""Run viewport replay state/math tests with a fake encoder, never a GPU."""
from pathlib import Path
import argparse
import subprocess
import tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[1])
args=parser.parse_args()
with tempfile.TemporaryDirectory(prefix='henge-viewport-replay-') as output:
    binary=Path(output)/'test'
    subprocess.run(['xcrun','clang','-target','arm64-apple-macos14','-fobjc-arc',
        '-Wall','-Wextra','-Werror','-I'+str(args.source_root.resolve()/'devices'),
        str(Path(__file__).with_suffix('.m')),'-framework','Foundation',
        '-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
