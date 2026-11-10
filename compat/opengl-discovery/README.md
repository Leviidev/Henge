# Process-scoped OpenGL renderer discovery

Sonoma's PV device lacks `IOGLBundleName` although its system AppleMetalOpenGLRenderer is present. This opt-in helper supplies that property only to a selected process, only for AppleParavirt registry objects, only when the property is absent. It neither changes the registry nor advertises invented hardware capabilities. Use it with Henge's late render-store-action fix. Context creation alone did not suffice before that fix: late attachment stores were lost and readback remained stale.

Build on an Apple Silicon Mac with Xcode, then copy the locally built output and this launcher to the Sonoma guest using your authenticated transfer mechanism:

```sh
python3 compat/opengl-discovery/build.py --output .compat-local/opengl-build
python3 compat/opengl-discovery/launch.py --shim /path/registry-discovery.dylib \
  --app /Applications/Supported.app --receipt /path/new-launch.json \
  --log /path/new-launch.log -- /path/media.mp4
```

Quit an existing app first and start a fresh process through the helper. Arguments after `--` go to the executable. `--executable` supports tools. `--dry-run` records preflight without launching. The app bundle is never modified. The launcher carries its `LSEnvironment` into the new process and removes the previous Henge software-fallback flag for this accelerated route. It refuses inherited DYLD injection; combine reviewed helpers with explicit repeated `--additional-dylib` arguments. Other helper-specific environment/configuration remains operator-supplied. It does not set global shell/login/LaunchServices variables.

Hardened runtime, library validation, SIP or app-specific launch restrictions may forbid injection. The launcher reports the known hardened-runtime restrictions; even a successful launch is not proof dyld accepted the library. Inspect the log for `CGLDISCOVERY` and verify the selected accelerated renderer/readback. Use an app build explicitly supporting injection; this package does not strip signatures, disable security features or re-sign arbitrary apps. Some applications require LaunchServices-specific startup beyond `LSEnvironment` and are outside this direct-launch route. Rollback is simply closing the launched app and opening it normally; no persistent registration exists to undo.

Run controls first on a native Mac to generate reference output, then in the guest with the helper. Use separate new output directories:

```sh
/path/draw_probe /path/native-probe.json
/path/draw_matrix /path/native-matrix
python3 launch.py --shim /path/registry-discovery.dylib --executable /path/draw_probe \
  --receipt /path/probe-launch.json --log /path/probe.log -- /path/guest-probe.json
python3 launch.py --shim /path/registry-discovery.dylib --executable /path/draw_matrix \
  --receipt /path/matrix-launch.json --log /path/matrix.log -- /path/guest-matrix
python3 check.py --probe /path/guest-probe.json --matrix /path/guest-matrix \
  --reference /path/native-matrix --require-paravirtual --output /path/comparison.json
```

The checks cover clear, GLSL triangle, nearest texture, indexed primitive restart, blend/scissor, depth rejection and framebuffer blit. Five 65×49 RGBA images matched the native control exactly on the tested Sonoma14.6.1/iPadOS17 route. This is bounded accelerated-rendering evidence, not a general claim for every OpenGL application, extension, OS or iPad. This source package contains no system renderer binary, captured shader, guest image or credentials. Host-native reruns qualify build and controls only; another iPad still requires its own guest run and visible application check.
