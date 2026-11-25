#!/bin/zsh
# Makes the Toolchain folder for Henge's terminal (Files > Henge > Projects > Toolchain) on a Mac with Xcode and
# Homebrew's python and ninja: clang, ld, the Swift compiler, the iPhone SDK, Python and a small shell, all of which
# run in Henge itself. Holds Apple's tools: for your own use.   make_toolchain.sh OUT
set -e
HERE=${0:a:h}; O=$1; BREW=${BREW:-$HOME/homebrew}
X=$(xcode-select -p); T=$X/Toolchains/XcodeDefault.xctoolchain/usr; S=$(xcrun --sdk iphoneos --show-sdk-path); S=${S:A}
mkdir -p $O/bin $O/lib $O/sdk; chmod -R u+w $O
for b in clang ld swift-frontend libtool lipo install_name_tool llvm-nm llvm-objdump; do cp -L $T/bin/$b $O/bin/$b; done
for l in libtapi libcodedirectory libLTO libswiftDemangle; do cp -L $T/lib/$l.dylib $O/lib/; done
for l in $(otool -L $T/bin/swift-frontend | awk '/@rpath/ {sub("@rpath/","",$1); print $1}'); do F=$(find $T/lib/swift/host -name $l | head -1); D=$O/${F#$T/}; mkdir -p ${D:h}; cp $F $D; done
for d in $(cd $T/lib/swift/host && find . -type d -name 'XcodeDefaultTools*'); do mkdir -p $O/lib/swift/host/$d; done
mkdir -p $O/lib/swift/host/plugins
cp -R $T/lib/swift/host/*.dylib $O/lib/swift/host/ 2>/dev/null || true
cp -R $T/lib/swift/host/plugins/*.dylib $X/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/*.dylib $O/lib/swift/host/plugins/ 2>/dev/null || true
for d in iphoneos shims apinotes; do [ ! -e $T/lib/swift/$d ] || cp -RL $T/lib/swift/$d $O/lib/swift/; done
# The newest processors' own modules: arm64e's serve arm64.
find $O/lib/swift -name 'arm64e.x1*' -delete
R=$($T/bin/clang -print-resource-dir); mkdir -p $O/lib/clang/${R:t}/lib/darwin; mkdir -p $O/lib/swift/clang; cp -R $R/include $O/lib/swift/clang/ # the Swift compiler looks there
cp -R $R/include $O/lib/clang/${R:t}/; cp $R/lib/darwin/libclang_rt.ios.a $O/lib/clang/${R:t}/lib/darwin/
rsync -a --exclude 'arm64e.x1*' --exclude PrivateHeaders --exclude 'usr/share' $S/ $O/sdk/iPhoneOS.sdk/; chmod -R u+w $O/sdk
find $O -type f \( -name '*.dylib' -o -perm -100 \) | while read f; do if lipo -info $f 2>/dev/null | grep -q "fat file.*arm64"; then lipo $f -thin arm64 -output $f.thin 2>/dev/null && mv $f.thin $f; fi; done
# Tools built here may call system(); it runs in Henge.
python3 - $O/sdk/iPhoneOS.sdk/usr/include/_stdlib.h <<'P'
import re, sys
s = open(sys.argv[1]).read()
open(sys.argv[1], "w").write(re.sub(r"(__API_AVAILABLE\(macos\(10\.0\)\)) __IOS_PROHIBITED\s*\n\s*__WATCHOS_PROHIBITED __TVOS_PROHIBITED\s*\n(int\s+system\()", r"\2", s))
P
# Python and the libraries it uses, found from beside it.
F=$(echo $BREW/Cellar/python@3*/*/Frameworks/Python.framework/Versions/3*(N[-1])); V=${F:t}
mkdir -p $O/python/lib/deps; cp /etc/ssl/cert.pem $O/python/cert.pem
rsync -a --exclude test --exclude __pycache__ --exclude idlelib --exclude tkinter --exclude turtledemo --exclude ensurepip --exclude 'config-*' --exclude site-packages $F/lib/python$V $O/python/lib/
mkdir -p $O/python/lib/python$V/site-packages
cp $F/Resources/Python.app/Contents/MacOS/Python $O/bin/python3; cp $F/Python $O/python/lib/deps/Python
todo=($O/bin/python3 $O/python/lib/deps/Python $O/python/lib/python$V/lib-dynload/*.so)
while (( $#todo )); do
  f=$todo[1]; shift todo; chmod u+w $f
  for l in $(otool -L $f | awk 'NR>1 {print $1}' | grep -E "^$BREW" || true); do
    n=${l:t}; d=$O/python/lib/deps/$n
    if [[ ! -e $d ]]; then cp -L $l $d; todo+=($d); fi
    case $f in (*/bin/*) p=@loader_path/../python/lib/deps ;; (*/deps/*) p=@loader_path ;; (*) p=@loader_path/../../deps ;; esac
    install_name_tool -change $l $p/$n $f 2>/dev/null
  done
done
python3 - $O/python/lib/python$V <<'P'
import sys
d = sys.argv[1]
open(d + "/subprocess.py", "a").write('''

# ---- Henge: no process can be made; what a program starts runs in this one through posix_spawn. ----
def _henge_execute_child(self, args, executable, preexec_fn, close_fds, pass_fds, cwd, env, startupinfo, creationflags, shell,
                         p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite, *rest):
    if isinstance(args, (str, bytes)): args = [args]
    elif isinstance(args, os.PathLike): args = [args]
    else: args = list(args)
    args = [os.fsdecode(a) for a in args]
    if shell: args = ["sh", "-c"] + args
    exe = os.fsdecode(executable) if executable and not shell else args[0]
    self.args_run = args
    env = dict(os.environ if env is None else {os.fsdecode(k): os.fsdecode(v) for k, v in env.items()})
    env["TL_SPAWN_CWD"] = os.path.abspath(os.fsdecode(cwd)) if cwd is not None else ""
    acts = [(os.POSIX_SPAWN_DUP2, a, b) for a, b in ((p2cread, 0), (c2pwrite, 1), (errwrite, 2)) if a != -1]
    try:
        if cwd is not None and not os.path.isdir(cwd): raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), cwd)
        self.pid = os.posix_spawnp(exe, args, env, file_actions=acts)
        self._child_created = True
    finally:
        self._close_pipe_fds(p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite)
Popen._execute_child = _henge_execute_child
''')
def edit(name, old, new):
    s = open(d + name).read()
    assert old in s, name
    open(d + name, "w").write(s.replace(old, new, 1))
edit("/multiprocessing/context.py", "        from .pool import Pool\n        return Pool(processes, initializer, initargs, maxtasksperchild,\n                    context=self.get_context())",
     "        from .pool import ThreadPool  # Henge: no processes\n        return ThreadPool(processes, initializer, initargs)")
s = open(d + "/concurrent/futures/__init__.py").read()
edit("/concurrent/futures/__init__.py", "lazy from .process import ProcessPoolExecutor" if "lazy from .process import ProcessPoolExecutor" in s else "from .process import ProcessPoolExecutor", "from .thread import ThreadPoolExecutor as ProcessPoolExecutor  # Henge: no processes")
open(d + "/site-packages/henge_start.pth", "w").write("import henge_start\n")
open(d + "/site-packages/henge_start.py", "w").write('''import os
def _system(command):
    import subprocess
    return subprocess.call(command, shell=True) << 8
os.system = _system
''')
P
cp -L $BREW/bin/cmake $BREW/bin/ninja $O/bin/; mkdir -p $O/share; rsync -a --exclude Help $BREW/Cellar/cmake/*/share/cmake $O/share/; chmod -R u+w $O/share
# Names other programs look for; tl_tool.h runs what they stand for.
for x in cc c++ clang++ bash python ar ranlib nm objdump; do echo 'another name' > $O/bin/$x; chmod 755 $O/bin/$x; done
cp -L $BREW/bin/glslc $O/bin/glslc 2>/dev/null || true
clang -w -O1 -target arm64-apple-ios17.0 -isysroot $S $HERE/sh.c -o $O/bin/sh # bash, clang++, python and cc are found as these (tl_tool.h)
cp $HERE/henge.cmake $O/; cp $HERE/CLAUDE.md $O/CLAUDE.md 2>/dev/null || true
du -sh $O
