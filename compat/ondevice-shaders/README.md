# In-process iPad shader conversion

Henge's ordered replay path keeps an accepted graphics batch pending until its
shader dependencies are ready. This provider performs cold AIR conversion on a
separate serial CPU queue inside Henge. It does not invoke a Mac compiler, SSH,
a subprocess, Metal compilation service, or an external helper executable.
Existing verified protocol3 cache entries remain an optional warm-first source;
the local provider also works when no Mac compiler configuration exists.

The provider returns source/output/profile-bound receipts. Each replay batch
retains the exact Ready result through function loading, independently of the
provider's bounded in-memory cache. Local cache writes go under
`Documents/shader-local-cache/<namespace>/<recipe>/`; old Mac cache/configuration
files are not overwritten. The production namespace is `production`.

For an isolated runtime acceptance test, set
`HENGE_LOCAL_SHADER_CACHE_NAMESPACE` before launching a fresh Henge process to a
new ASCII name of 1–64 letters/digits/underscores/hyphens. Keep existing caches and
compiler services intact. Use newly authored guest shader inputs to force cold
source hashes. Record provider `compiled` events, request UUID, source hash,
recipe, namespace and compile timing; a renderer's later `ondevice-compiled`
selection describes retained byte provenance and does not by itself prove a new
compilation. Cached results report their current cache route separately from the
original producer receipt. Remove the test environment setting to return to the
production namespace; no cache deletion is needed.

## Rebuild for an iOS application

An Apple Silicon build machine with Xcode, Python3, CMake, Ninja and Git is required
to produce the app. Users running the resulting app do not need a Mac compiler.
LLVM source is public and pinned to commit
`6a133d69154dfaffa04a6339a3178db328bd98a5` of
`https://github.com/gzorin/floor_llvm`. Obtain a clean checkout yourself or in CI,
then run from the Henge repository:

```sh
python3 tools/compat/build_ondevice_provider.py \
  --llvm-source /absolute/path/to/clean/floor_llvm \
  --output /absolute/path/to/new/provider-build --jobs 4
make ios-lib
zsh ios/scripts/package_ipa.sh --trollstore
```

The helper copies this source package to a new build directory, verifies the LLVM
commit, applies the included embedding/hardening changes there, builds native and
iOS libraries, generates a source/tool/library-bound recipe, and stages the single
combined `libHGOnDeviceShader.a` in ignored `ios/deps/lib/`. The app links that
archive once and `libc++`; do not separately compile the provider/CABI sources
into the same app. No shader assets or private Apple compiler binaries are bundled.
The caller header and profile contract copies must match `devices/` before build.

The packaging step verifies the staged archive hash, exact provider-source hashes,
recipe identity, header contracts and bundled LLVM license. A missing or stale
`ios/deps/lib/libHGOnDeviceShader.build.json` requires a provider rebuild; copying
an archive alone is insufficient. The build helper rejects source changes while
compilation is in progress.

The pinned-source helper completed a new native and iOS build from a clean LLVM
checkout, then passed the generated native controls, including 256 exact compute
values. A complete iOS app package also passed the staged-provider check. This is
build/native evidence; the newly reconciled app still needs its own iPad runtime
gate. See [distribution validation](../../docs/compatibility/distribution-validation.md).
Archive bytes and recipes may change across build paths/toolchains. Regenerate and record the recipe instead
of assigning a previous binary's identity to a rebuild. Preserve the included
LLVM license and exact dependency/source provenance when distributing a build.

## Limits and acceptance

Input 8 MiB, output 16 MiB, pending 8 jobs/32 MiB, and Ready 128 entries/32 MiB are explicit
provider limits. LLVM's reader has a cooperative operation/time budget; an
executing CPU job is not forcibly killed on cancellation. VM stop invalidates
publication and wake callbacks; an already-started atomic cache write may finish
valid bytes. Running CPU jobs share one process-wide serial queue across VM
instances. Unsupported inputs fail visibly; they are never treated as successful
stand-in shaders.

The linked candidate's native provider tests, authored compute/render controls
and structural corpus conversion are separate from the integrated iPad runtime
gate. A parked dependency still delays the guest operation that needs it. This is
not a claim that every shader or arbitrary application is supported, or that
queueing alone makes a cold shader instantaneous. Validate real cold rendering,
query/readback ordering, task reuse, mapper completion, background/resume and
shutdown on the final installed app. Historical AGX faults remain a separate
investigation.
