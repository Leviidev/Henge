#!/usr/bin/env python3
"""Explicit foreground compiler lifecycle. No service/login item installation."""
import argparse,os,runpy,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
p=argparse.ArgumentParser(add_help=False);p.add_argument('--build-dir',type=Path,default=ROOT/'build');a,rest=p.parse_known_args();os.environ['HENGE_DYNAMIC_BUILD']=str(a.build_dir.resolve());sys.path.insert(0,str(ROOT/'compiler'));sys.argv=[str(ROOT/'compiler/dynamic_peer_http.py'),*rest];runpy.run_path(sys.argv[0],run_name='__main__')
