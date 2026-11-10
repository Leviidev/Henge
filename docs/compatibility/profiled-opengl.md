# Paired OpenGL shader and viewport compatibility

Protocol3 qualifies transformed shader bytes before they can mark a render
pipeline. The compiler recognizes `OpenGL GLSL` language metadata, verified
vertex entrypoints and the exact `air.position` float4 output. It changes only
that position's z component to `(z+w)/2`, retains the other outputs and marks the
transformation idempotently. Non-GL and fragment-only IR is unchanged by this
lowering pass. Platform recompilation remains a separate compiler operation.

The paired host replay maps the GL producer's raw near value back to
`2*rawNear-rawFar`, retaining rawFar, dimensions, array count and setter mode.
It uses the successful pipeline's actual final vertex function, including after
retry. Raw viewport bytes are saved per render encoder and reapplied on pipeline
switches, so conversions do not accumulate. Unknown/unmarked pipelines use the
original viewport. No synthetic viewport or depth-clamp default is introduced.

Do not deploy vertex lowering alone. The required pair is the protocol3
converter/profile loader plus `pvg_viewport_replay.h` and its render replay
integration. Unknown schemas, fractional/boolean integer fields, wrong
source/recipe/output hashes, changed lengths and unbound profiles are rejected.
Protocol3 does not fall back to unprofiled converted libraries. Protocol2 scripts
remain available under their original names and retain their prior policy.

## Compiler Mac build and identity

The tested host uses Xcode27.2 build27B52, its Metal toolchain, Python3.9+ and
LLVM23.1.4 development headers/libraries. Use your own licensed SDK/toolchain;
this repository does not distribute them or a compiled planner. Select the
intended Xcode with `xcode-select`; the companion pins that selected developer
directory for its child compilers. Supply the LLVM installation explicitly:

```sh
export HENGE_LLVM_CONFIG=/absolute/path/to/llvm-config
python3 ios/scripts/build_gl_position.py --llvm-config "$HENGE_LLVM_CONFIG"
python3 tools/compat/external_toolchain.py --llvm-config "$HENGE_LLVM_CONFIG" \
  --output /path/new-private-toolchain-receipt.json
```

The generated `ios/scripts/gl-position-plan` and its build log are ignored by
Git. Rebuilding the frozen planner on the tested host reproduced its reference
SHA256 exactly. The source inventory is [protocol3-source-provenance.json](protocol3-source-provenance.json).
The runtime recipe includes converter/profile/planner sources, planner executable,
Metal/metallib executables, LLVM runtime libraries, SDK build and target. Paths
also contribute to this recipe: compute it in the final compiler checkout.
Moving/rebuilding the compiler may require a new cache namespace. Never assign
an old protocol2 recipe or receipt to protocol3 bytes.

The tested production recipe was
`5b281b1bdc0372b8fa7268adbeca926915eaa219954da7b7fb313dc71670d4f3`.
That is an evidence identity, not a recipe constant to paste into another setup.

## Activation and rollback

1. Build/install the paired Henge source using the [guarded in-place updater](reproduce-ios17.md).
   Preserve a known-good TIPA and its private data-preservation receipts.
2. Close the guest applications whose pipelines will change. Stop the prior
   static shader companion so it releases its ownership lock/lease. Save a
   byte-for-byte private copy of Henge Documents' `shader-compiler-config.json`,
   or explicitly record that it was absent. Preserve old recipe caches and
   manually validated legacy libraries.
3. Start the profiled companion in the foreground on the compiler Mac:

```sh
python3 ios/scripts/shader_companion_profiled.py \
  --host YOUR_VERIFIED_SSH_HOST --documents /absolute/Henge/Documents \
  --cache /absolute/private/profiled-compiler-cache
```

This uses the tested iPad SSH route and `/var/jb/usr/bin/python3` on the iPad;
it does not need guest-macOS Python or CLT. Establish the SSH host key and your
authentication locally first. `--host-key-alias` supports an existing verified
alias. The peer embeds its profile validator, publishes a protocol3 config and
short-lived owned lease, and writes only recipe-qualified outputs/receipts.
It does not overwrite the old manually validated legacy cache. A successful
receipt is published after its bytes. `--local` is an isolated host test mode,
not a device installation shortcut.

4. Launch a fresh supported OpenGL process through the
   [process-scoped discovery helper](../../compat/opengl-discovery/README.md).
   Protocol3 is a Henge shader-conversion policy; renderer discovery remains
   per-process. The dynamic-library HTTP compiler is separate. If using its
   cold dynamic path while protocol3 is active, keep both required compilers
   available until both cache layers have been filled and checked.
5. Verify fresh task/function provenance and actual pixels. Stopping the
   companion with Ctrl-C revokes its owned lease but leaves protocol3 and valid
   cached outputs active. Cached offline behavior is intentional; a cold miss
   still needs the compiler and must not silently use unprofiled bytes.

To deactivate, close the affected guest apps and stop the profiled companion.
Restore the exact previous config, or remove only that active config if it was
originally absent. Preserve caches rather than relabel or overwrite them.
Restart applications so task/PSO lifetimes are fresh. Start the old protocol2
companion explicitly if uncached old-policy conversions are needed. If rolling
back the Henge app too, restore the matching compiler policy first, then halt
and use the same guarded TIPA update route. Never uninstall Henge or restore a
stale guest disk to roll back this source change. Do not copy transformed
protocol3 outputs into bare protocol2 legacy cache filenames.

## Reproducible controls and scope

```sh
python3 -m unittest discover -s ios/scripts -p 'test_gl_position.py'
python3 -m unittest discover -s ios/scripts -p 'test_profile.py'
python3 -m unittest discover -s ios/scripts -p 'test_profiled_authored.py'
python3 tests/test_pvg_viewport_replay.py
python3 tests/test_pvg_task_lifecycle.py
python3 tests/test_pvg_ordinary_texture.py
```

The portable planner tests use authored IR, including multiple returns,
non-unit w, reversed ranges, non-GL identity and unsupported metadata. Profile
controls compare Python and native validation and exercise eight load-policy
cases without a GPU. The authored end-to-end control compiles a fresh MSL ABI
fixture, explicitly tags its coordinate contract, converts/publishes it and
checks bound-cache reuse/tamper rejection; it is not a captured GLSL frontend
fixture or a GPU execution test. There are126 viewport state/math checks,
11 lifecycle checks and977 ordinary-texture CPU sanitizer checks.

Private retained VLC AIR/metallib tests skip unless the operator supplies
`HENGE_GL_VLC_VERTEX_IR` / `HENGE_GL_VLC_METALLIB`. No captured shader or fixture
binary is distributed. A compiler test pass does not substitute for actual
rendering on the target device.

The production lineage independently passed all797 prewarm outputs with full
profile bindings (eight GL profiles). That is compile/profile coverage, not797
GPU execution tests. Actual unmodified GL controls passed21/21 depth cases twice
and17 native-reference image cases, with no diagnostic viewport hook. VLC H.264,
HEVC and10-bit HEVC playback also advanced through the real OpenGL layer; broader
media, all extensions and all applications are not thereby qualified. The
separately reconciled latest-upstream branch still needs its own device gate.
