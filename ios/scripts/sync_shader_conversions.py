#!/usr/bin/env python3
"""Capture iPad guest libraries, compile missing iOS fallbacks, optionally install.

Requires SSH access and Python 3 on the iPad, plus Xcode's Metal compiler on the
Mac. Existing iPad conversions are retained. Run again to collect newly generated
variants. A successful compile does not establish runtime or visual correctness.
"""
import argparse
import concurrent.futures
import hashlib
import io
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--host-key-alias")
    parser.add_argument("--documents", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--retry", action="store_true",
                        help="publish shader-retry after installation; requires the retry-enabled Henge build")
    args = parser.parse_args()
    if args.retry and not args.install:
        parser.error("--retry requires --install")
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    if args.host_key_alias:
        ssh += ["-o", f"HostKeyAlias={args.host_key_alias}"]
    ssh += [args.host]

    def remote(code, data=None):
        return subprocess.run(ssh + ["python3 -c " + shlex.quote(code)],
                              input=data, capture_output=True, check=True, timeout=180).stdout

    root = args.workspace.resolve()
    guest, ios = root / "guest", root / "ios"
    guest.mkdir(parents=True, exist_ok=True)
    ios.mkdir(parents=True, exist_ok=True)
    capture = remote(f'''
import pathlib,tarfile,sys,io,json
p=pathlib.Path({args.documents!r})
with tarfile.open(fileobj=sys.stdout.buffer,mode="w|") as t:
    for f in sorted(p.glob("sonoma-guestlib-*.metallib")):
        if f.is_file(): t.add(f,arcname=f.name,recursive=False)
    data=json.dumps(sorted(f.name for f in p.glob("sonoma-ioslib-*.metallib"))).encode()
    m=tarfile.TarInfo("installed.json");m.size=len(data);t.addfile(m,io.BytesIO(data))
''')
    sources = {}
    installed = set()
    total = 0
    with tarfile.open(fileobj=io.BytesIO(capture)) as archive:
        for member in archive:
            if not member.isfile() or member.size > 32 * 1024 * 1024:
                raise ValueError("unexpected archive member")
            total += member.size
            if total > 128 * 1024 * 1024:
                raise ValueError("capture exceeds 128 MiB limit")
            data = archive.extractfile(member).read()
            if member.name == "installed.json":
                installed = set(json.loads(data))
                continue
            if not re.fullmatch(r"sonoma-guestlib-[0-9a-f]+\.metallib", member.name):
                raise ValueError(f"unexpected capture name {member.name!r}")
            digest = hashlib.sha256(data).hexdigest()
            suffix = member.name[len("sonoma-guestlib-"):-len(".metallib")]
            if len(suffix) == 64 and suffix != digest:
                raise ValueError(f"capture hash mismatch: {member.name}")
            if data[:4] != b"MTLB":
                raise ValueError(f"invalid library: {member.name}")
            sources.setdefault(digest, []).append(member.name)
            (guest / f"sonoma-guestlib-{digest}.metallib").write_bytes(data)
    print(f"Captured {sum(map(len, sources.values()))} files, {len(sources)} unique libraries", flush=True)
    compiler = Path(__file__).with_name("recompile_guest_metallib.py")

    def compile_one(digest):
        name = f"sonoma-ioslib-{digest}.metallib"
        result = {"sha256": digest, "sources": sources[digest], "output": name}
        if name in installed:
            return dict(result, status="retained on device")
        process = subprocess.run([sys.executable, str(compiler),
                                  str(guest / f"sonoma-guestlib-{digest}.metallib"),
                                  "--output-dir", str(ios)], capture_output=True, text=True, timeout=90)
        return dict(result, status="compiled" if process.returncode == 0 else "failed",
                    diagnostic=process.stderr.strip())

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(compile_one, sorted(sources)))
    additions = [item["output"] for item in results if item["status"] == "compiled"]
    report = {"host": args.host, "libraries": results, "additions": additions, "installed": False}
    (root / "sync-report.json").write_text(json.dumps(report, indent=2))
    print(f"Compiled {len(additions)} additions; failures: {sum(r['status'] == 'failed' for r in results)}", flush=True)
    if args.install:
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w") as archive:
            for name in additions:
                archive.add(ios / name, arcname=name, recursive=False)
        receipt = remote(f'''
import pathlib,tarfile,sys,re,os,tempfile,json
p=pathlib.Path({args.documents!r});added=[]
with tarfile.open(fileobj=sys.stdin.buffer,mode="r|") as t:
    for m in t:
        if not m.isfile() or not re.fullmatch(r"sonoma-ioslib-[0-9a-f]{{64}}\\.metallib",m.name) or m.size>32*1024*1024: raise ValueError("invalid conversion")
        data=t.extractfile(m).read()
        if data[:4]!=b"MTLB": raise ValueError("invalid library")
        dest=p/m.name
        if dest.exists(): continue
        fd,tmp=tempfile.mkstemp(prefix=".shader-upload-",dir=p)
        try:
            with os.fdopen(fd,"wb") as f: f.write(data)
            os.chmod(tmp,0o644);os.replace(tmp,dest);added.append(m.name)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
if {args.retry!r}: (p/"shader-retry").touch()
print(json.dumps(added))
''', payload.getvalue())
        report.update(installed=True, installed_additions=json.loads(receipt), retry_requested=args.retry)
        (root / "sync-report.json").write_text(json.dumps(report, indent=2))
        print(f"Installed {len(report['installed_additions'])} additions; retry requested: {args.retry}")
    return int(any(r["status"] == "failed" for r in results))


if __name__ == "__main__":
    raise SystemExit(main())
