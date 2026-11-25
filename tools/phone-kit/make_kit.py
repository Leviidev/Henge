#!/usr/bin/env python3
"""Make a kit for building a CMake/Ninja iPhone project in Henge itself (Mac Apps, Open in a Terminal), without macOS.

  make_kit.py SOURCE_ROOT BUILD_DIR TARGET APP KIT [--prebuilt TEXT]... [--run FILE]

On a Mac, after a full build of TARGET in BUILD_DIR (with compile_commands.json): copies the sources the build used, its
objects and libraries, and Xcode's clang, ld and iPhone SDK into KIT, with henge-build.json (ios/Henge/ProjectBuilder.swift).
--prebuilt TEXT: sources whose path has TEXT are left out (their objects are linked as they are). The result holds
Apple's tools: for your own use.
"""
import argparse, hashlib, json, os, shlex, shutil, subprocess, sys

ap = argparse.ArgumentParser()
for n in ("source", "build", "target", "app", "kit"): ap.add_argument(n)
ap.add_argument("--prebuilt", action="append", default=[])
ap.add_argument("--run", help="a JSON file: how the program runs without its window (ProjectBuilder.Run)")
ap.add_argument("--ninja", default="ninja")
a = ap.parse_args()
root, build, kit = (os.path.realpath(x) for x in (a.source, a.build, a.kit))
sdk = os.path.realpath(subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip())
tool = os.path.dirname(os.path.dirname(subprocess.check_output(["xcrun", "-f", "clang"], text=True).strip()))
ninja = lambda *x: subprocess.check_output([a.ninja, "-C", build, *x], text=True)
app = os.path.join(build, a.app)

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()[:24]
def put(src, rel):
    dst = os.path.join(kit, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)  # links become the files they name
def rel(p):
    """Where a file of the source or build folder goes in the kit."""
    p = os.path.normpath(p if os.path.isabs(p) else os.path.join(build, p))
    if p.startswith(build + "/"): return "build/" + p[len(build) + 1:]
    if p.startswith(root + "/"): return "source/" + p[len(root) + 1:]
    return None
sdks = sorted((os.path.join(os.path.dirname(sdk), n) for n in os.listdir(os.path.dirname(sdk)) if n.endswith(".sdk")), key=len, reverse=True)
def sub(s):
    for old, new in [(build, "$KIT/build"), (root, "$KIT/source")] + [(x, "$KIT/sdk") for x in sdks] + [(tool, "$KIT/toolchain")]:
        s = s.replace(old, new)
    return s

commands = ninja("-t", "commands", a.target).split("\n")
deps, cur = {}, None
for line in ninja("-t", "deps").split("\n"):
    if line and not line[0].isspace(): cur = deps.setdefault(line.split(":")[0], [])
    elif line.strip(): cur.append(line.strip())

flags, flag_at, files, file_at, units, objs = [], {}, [], {}, [], set()
for c in commands:
    if " -c " not in c or " -o " not in c: continue
    w = shlex.split(c)
    if "-c" not in w or not os.path.basename(w[0]) in ("cc", "c++", "clang", "clang++"): continue
    src, obj = w[w.index("-c") + 1], w[w.index("-o") + 1]
    objs.add(obj)
    if any(t in src for t in a.prebuilt): continue
    f, skip = ["--driver-mode=g++"] if "++" in os.path.basename(w[0]) else [], False
    for x in w[1:]:
        if skip: skip = False
        elif x in ("-c", "-o", "-MF", "-MT"): skip = True
        elif x in ("-MD", "-MMD"): pass
        else: f.append(sub(x))
    f += ["-resource-dir", sub(subprocess.check_output([tool + "/bin/clang", "-print-resource-dir"], text=True).strip())]
    key = "\0".join(f)
    if key not in flag_at: flag_at[key] = len(flags); flags.append(f)
    ds = []
    for d in dict.fromkeys([src] + deps.get(obj, [])):
        full = os.path.normpath(os.path.join(build, d))
        r = rel(full)
        if r is None or not os.path.isfile(full): continue
        if r not in file_at:
            file_at[r] = len(files); files.append(r); put(full, r)
        ds.append(file_at[r])
    units.append({"src": rel(src), "obj": rel(obj), "flags": flag_at[key], "deps": ds})

link = next(c for c in reversed(commands) if f"-o {a.app}/" in c)
link = link.split("&&")[1].strip() if link.startswith(":") else link.split("&&")[0]
text = subprocess.run(link + " -###", shell=True, cwd=build, capture_output=True, text=True).stderr.strip().split("\n")[-1]
args, out, program, skip = shlex.split(text)[1:], [], None, False
for i, x in enumerate(args):
    if skip: skip = False; continue
    if x == "-lto_library": skip = True; continue
    if i and args[i - 1] == "-o": program = rel(x); out.append("$KIT/" + "app/" + os.path.relpath(os.path.join(build, x), build)); continue
    full = os.path.normpath(os.path.join(build, x))
    if not x.startswith("-") and rel(full) and os.path.isfile(full):
        put(full, rel(full)); out.append("$KIT/" + rel(full)); continue
    out.append(sub(x))
    if x.startswith(tool) and os.path.isfile(x): put(x, "toolchain" + x[len(tool):])
for n in ("bin/clang", "bin/ld", "lib/libtapi.dylib", "lib/libcodedirectory.dylib", "lib/libLTO.dylib", "lib/libswiftDemangle.dylib"):
    src, dst = os.path.join(tool, n), os.path.join(kit, "toolchain", n)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.check_call(["lipo", src, "-thin", "arm64", "-output", dst]) if "fat file" in subprocess.check_output(["lipo", "-info", src], text=True).replace("Non-fat", "") else shutil.copy2(src, dst)
res = subprocess.check_output([tool + "/bin/clang", "-print-resource-dir"], text=True).strip()
shutil.copytree(res + "/include", os.path.join(kit, sub(res)[len("$KIT/"):], "include"), dirs_exist_ok=True)
for n in ("SDKSettings.json", "SDKSettings.plist"): put(os.path.join(sdk, n), "sdk/" + n)
drop = shutil.ignore_patterns("*.swiftmodule", "*.swiftcrossimport", "*.apinotes", "share", "PrivateHeaders")
for n in ("usr/include", "usr/lib", "System/Library/Frameworks"):
    shutil.copytree(os.path.join(sdk, n), os.path.join(kit, "sdk", n), ignore=drop, dirs_exist_ok=True)
shutil.copytree(app, os.path.join(kit, "app", a.app), ignore=shutil.ignore_patterns(os.path.basename(app)[:-4]), dirs_exist_ok=True)
name = os.path.basename(kit)
exe = os.path.basename(app)[:-4]
json.dump({"name": name, "flags": flags, "files": files, "hashes": [sha(os.path.join(kit, f)) for f in files], "units": units,
           "clang": "toolchain/bin/clang", "ld": "toolchain/bin/ld", "link": out, "program": f"app/{a.app}/{exe}",
           "app": f"app/{a.app}", "ipa": f"{name}.ipa", "run": json.load(open(a.run)) if a.run else None}, open(os.path.join(kit, "henge-build.json"), "w"), indent=0)
print(len(units), "to compile here,", len(objs), "objects,", len(files), "files,", len(flags), "sets of flags")
