#!/usr/bin/env python3
"""Run authored controls with the same executable-relative asset layout as iOS."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from shader_inventory_device_review import review


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('kit',type=Path);a=p.parse_args();root=a.kit.resolve()
    layout=root/'native-auditassets-layout';layout.mkdir(exist_ok=True);assets=layout/'AuditAssets'
    shutil.copytree(root/'NativeResources',assets,dirs_exist_ok=True)
    binary=layout/'native-runner';source=Path(__file__).with_name('shader_inventory_device_runner.m').resolve();commands=[]
    for command in [['xcrun','--sdk','macosx','clang','-arch','arm64','-mmacosx-version-min=14.0','-std=gnu11','-fobjc-arc','-fblocks',str(source),'-framework','Foundation','-framework','Metal','-framework','AppKit','-o',str(binary)],
                    [str(binary),str(assets),str(layout/'results'),'--inventory-stage','controls']]:
        cp=subprocess.run(command,capture_output=True,text=True,timeout=100);commands.append({'command':command,'returncode':cp.returncode,'stdout':cp.stdout,'stderr':cp.stderr})
        if cp.returncode:raise RuntimeError(cp.stderr)
    latest=json.loads((layout/'results/inventory-latest.json').read_text())['relative_directory'];report_path=layout/'results'/latest/'inventory-report.json'
    result=review((assets/'inventory-jobs.json').read_bytes(),json.loads(report_path.read_text()));result.update(report=str(report_path),executable=str(binary),asset_directory=str(assets),executable_relative_layout='AuditAssets')
    (root/'native-auditassets-layout-commands.json').write_text(json.dumps(commands,indent=2)+'\n');(root/'native-auditassets-layout-review.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));raise SystemExit(bool(result['issues']))


if __name__=='__main__':main()
