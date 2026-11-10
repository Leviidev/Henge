# Opt-in stateless Metal dynamic libraries

This package adds a bounded compute-only compatibility path to the Sonoma Apple
Paravirtual Metal device. It preserves ordinary `MTLDynamicLibrary` calls in the
selected process. A Mac compiler resolves immutable AIR dependency closures; the
guest then submits ordinary executable functions through Henge's existing replay.

It does not install a guest service, modify applications, patch driver binaries,
change global capabilities, disable library validation, or require guest Python or
Xcode. Activation uses a per-process injected dylib. Applications whose signing
policy blocks injected libraries remain unsupported by this launcher.

## Build on the compiler Mac

Requirements: Xcode with the Metal command-line toolchain, Python3, and LLVM
headers/tools (`llvm-config`, `llvm-dis`). LLVM23 and the tool versions recorded in
`build/recipe.json` were validated. Set `HENGE_LLVM_CONFIG` when LLVM is elsewhere.

```sh
python3 build.py --output build
python3 controls/build_controls.py --output build-controls
```

`build/henge-dynamic-guest.tar.gz` contains the adapter and shell launch/install/
rollback tools. `build-controls/authored-controls.tar.gz` contains executables and
newly compiled authored fixtures. Producers explicitly set and verify executable
archive modes. No Apple binaries, captured shader libraries, credentials, or device
identifiers are checked into this source package.

A recipe binds the adapter/compiler sources, tool versions, target policy and
limits. Rebuild after changing those inputs; old requests cannot be relabeled with
a new recipe. `--native-test` creates a separately identified build that permits
physical-Mac testing when `HENGE_DYNAMIC_TEST_DEVICE=1`; use a normal build in the
guest. Normal activation is restricted to the unsupported `AppleParavirtDevice`
on macOS14.

## Configure and start the compiler

Choose your endpoint, guest token path and cache location explicitly. Configuration
is generated on the Mac; paths containing `~` are expanded by the guest adapter.

```sh
python3 configure.py --build-dir build \
  --endpoint http://COMPILER_ADDRESS:PORT \
  --guest-token-file '~/Library/Application Support/Henge/dynamic-token' \
  --guest-cache-directory '~/Library/Caches/Henge/DynamicLibraries' \
  --generate-token compiler-token --output guest-config.json

python3 serve.py --build-dir build --bind BIND_ADDRESS --port PORT \
  --token-file compiler-token --exchange compiler-exchange \
  --work compiler-work --seconds 1800
```

Copy the token privately to the configured guest path and the configuration to a
chosen guest location. Do not package credentials. The compiler runs in the
foreground for the declared duration; Ctrl-C stops it. The default bind is
localhost; choose forwarding or a reachable interface deliberately. The endpoint
requires bearer authentication. HTTPS can be supplied by an existing TLS proxy;
HTTP itself does not encrypt traffic.

No temporary Henge controller, numbered job, SSH session, shared-folder relay or
background guest script is part of compilation. The adapter publishes and polls
requests itself using `NSURLSession`. Cached valid closures load with the compiler
offline. A cache miss requires the configured compiler and returns a bounded error
if it is unavailable.

## Run a selected executable in Sonoma

Extract the guest archive and optionally install a user-owned version:

```sh
bash ./install.sh "$HOME/Library/Application Support/Henge/DynamicLibraries"
```

The installer prints the versioned path. It verifies the package manifest and does
not overwrite a changed version. Launch only the intended executable:

```sh
bash /PATH/TO/VERSION/run.sh --config /PATH/guest-config.json -- \
  /PATH/TO/EXECUTABLE ARGUMENTS
```

The launcher refuses inherited `DYLD_INSERT_LIBRARIES`. For explicit combined
OpenGL/dynamic injection, use the compatibility OpenGL launcher's
`--additional-dylib /PATH/libHengeDynamic.dylib` and set
`HENGE_DYNAMIC_CONFIG=/PATH/guest-config.json`. That launcher also handles `.app`
selection and library-validation checks. Neither launcher re-signs applications.

The shim interposes the public default/enumerated Metal-device factory functions.
Other private factory paths are not claimed. Only opted-in processes see the
compute capability; render/stateful capabilities remain false. Unrelated ordinary
pipelines continue through their existing implementation. Dynamic render requests
containing compatibility dependencies receive an explicit unsupported error.

## Authored runtime gates

Run these under the same launcher and compiler. Relative output directories are
canonicalized by the controls before constructing absolute install names.

```sh
bash /PATH/TO/VERSION/run.sh --config /PATH/guest-config.json -- \
  ./dynamic-controls ./AuditAssets ./matrix-results --inventory-stage controls
bash /PATH/TO/VERSION/run.sh --config /PATH/guest-config.json -- \
  ./async-lifetime ./async-results
bash /PATH/TO/VERSION/run.sh --config /PATH/guest-config.json -- \
  ./dependency-snapshot ./snapshot-results
```

Review the actual executable exit code, not a later archive/upload command.
Expected gates:

- Three path-qualified routes:768 exact uint32 values. The relative-source/no-URL
  control remains rejected. Packed function constants:1,024 exact values.
- Async source callbacks twice and pipeline callback once;256 exact values; weak
  library/function/dynamic references released at the post-dispatch check.
- Two dynamic objects with the same install name but different bodies: the new
  pipeline changes result, and the original pipeline retains its result after
  replacement. Both wrappers are released;768 exact values.
- Reports reference raw readback files. Requests, compiler commands, input/output
  digests, receipts and tool recipe provide independent provenance.

The V2 precursor and native injected controls remain separate evidence. The
production injected package with recipe
`5c6b17259467c6a3c45c92b600207bfc06f581d6d2b1431df483ed6dd09ae097`
also passed its independent actual Sonoma14.6.1 PV-device gate: 2,816 exact raw
uint32 values across all three executables, all exits0, correct callback counts
and weak-reference release, and six automatic authenticated cold requests with
no guest relay. Its user-owned versioned installer passed on that guest.

With both Mac compilers stopped, cached asynchronous and dependency-snapshot
execution passed another 1,024 exact values and clean exits. That is bounded
warm-cache evidence; cold misses still require the configured compiler. It does
not qualify dynamic render/stateful features, every app, or another OS/device.
Source/recipe identity was unchanged between the cold and offline gates.

For native-only integration testing:

```sh
python3 build.py --native-test --output native-build
python3 tests/native_integration.py --build native-build \
  --controls build-controls --output native-results
```

This starts a temporary authenticated localhost peer, runs ordinary API clients,
then stops the peer and tests cached asynchronous execution. It closes its endpoint
and deletes the temporary token. It never contacts a guest or controller.

## Boundaries and lifecycle

Supported scope is AIR-backed, stateless compute with tracked function-by-name
creation and one consumer entrypoint per compiled request. Source libraries,
file/data libraries, serialized compatibility dynamic libraries, synchronous and
asynchronous source compilation, and public compute pipeline overloads are
handled. Argument buffers and dispatch encoding remain the caller's responsibility.

Stateful globals, dynamic function constants, visible function pointers, ambiguous
exports/interposition, dependency cycles, `@rpath`, vendor GPU-binary dynamic
libraries, and private loader ABI equivalence are unsupported. Unknown contracts
fail explicitly. AOT pipeline archives and alternate function-descriptor creation
paths are not covered. The host limits dependencies/modules/bytes and kills compiler
process groups on timeout; the client has a bounded request deadline.

Dependency resolution preserves original bytes, install names and consumer origins.
Apple linking alone leaves stale AIR dynamic routing tables. The lowering removes
those only after the LLVM graph proves every import resolves to a local definition
and the routing tables have no shader-code users. Apple textual IR preserves the
original ABI spelling; function bodies and metadata are not replaced with authored
substitutes. Rendering is not inferred from library load or successful linking.

To stop use, close the opted-in application and launch it normally. Stop the host
compiler. To remove one installed unchanged version, run its `uninstall.sh`; it
refuses changed/extra files and never removes configuration, tokens or caches.
Cache data lives only under the configured directory and recipe digest. Retain it
for offline operation or remove that explicitly selected recipe directory while
opted-in applications are stopped. There is no global rollback operation.
