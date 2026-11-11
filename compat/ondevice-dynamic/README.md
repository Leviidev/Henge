# Embedded stateless dynamic closure port

This prototype ports the existing bounded stateless compute closure to the
public LLVM reader/linker/writer already used by Henge's on-device provider.
The C ABI reads only supplied byte arrays and declared origins. It neither runs
Apple compiler tools nor searches a filesystem/network for dependencies.
The provider build includes this backend in its combined source-bound archive.
The iOS sharing bridge now registers a private guest-only HTTP service that
uses the ordinary provider's shared compiler queue. Once loaded, the guest
adapter discovers its recipe and endpoint without a Mac address or token.
Automatic guest delivery and application activation remain unfinished. The
existing installed iPad Henge has not been replaced by this build.
It does not remove the remaining setup requirements by its presence in the PR.

The initial reviewed input profile is macOS 14 MTLB 2.7 / AIR 2.6 / Metal 3.1,
one consumer compute entrypoint, at most 16 declared libraries / 64 AIR modules,
16 MiB aggregate input/output and 131072 instructions. Dynamic dependencies must
be stateless direct functions. Loader-relative and absolute declared dependencies
and explicit preloads retain the existing resolution policies. Executable/rpath
expansion, mutable dependency globals, aliases, indirect calls, ambiguous symbols,
cycles and unresolved imports are rejected. Other version/profile combinations
still need implementation and qualification before being accepted.

The port validates container extents, function inventories and AIR hashes;
resolves the declared dependency graph; compares container and IR imports; links
concrete definitions; validates removal of the routing globals; internalizes
helpers; writes the existing AIR bitcode version; and rebuilds the consumer's
container while preserving its public/private/reflection records. Optional iOS
retargeting changes the actual module target as well as the container header.
Unknown records are rejected instead of guessing relocation semantics.

## Reproduce authored controls

First build the pinned provider using
[the ordinary compiler recipe](../ondevice-shaders/README.md), then build its
additional public LLVM components:

```sh
cmake --build PROVIDER/llvm-native -j 4 --target LLVMLinker llvm-dis
cmake --build PROVIDER/llvm-ios -j 4 --target LLVMLinker
python3 compat/ondevice-dynamic/build_fixtures.py --output NEW_FIXTURES
python3 compat/ondevice-dynamic/build_control.py --provider-build PROVIDER \
  --provider-archive PROVIDER/lib-macosx/libHGOnDeviceShader.a --output NEW_BUILD
python3 compat/ondevice-dynamic/qualify_native.py --control NEW_BUILD/native-control \
  --fixtures NEW_FIXTURES --output NEW_RESULTS
```

Fixture generation uses the build Mac's Apple tools to compile newly authored
source. Execution of the resulting C ABI controls uses the embedded public LLVM
code and ordinary Metal APIs. No captured shader libraries are distributed.
Three successful native and direct iPad cases checked 768 exact compute outputs
on each device. The subsequent export/definition binding guard has native-only
qualification so far. Rejection controls
must return before publishing a library or calling Metal.

For a direct iPad control, `build_device.py --provider-build PROVIDER --fixtures
NEW_FIXTURES --output NEW_DEVICE_BUILD` generates an unsigned audit app. Signing,
installation and trust are operator-owned test actions, not production setup.
This direct Metal test is separate from the still-required guest adapter,
automatic activation, recipe/cache binding and Henge integration gates.


## Private guest transport

The iOS app registers `HGOnDeviceDynamicService` on the existing virtual network
share at `10.0.2.4/.henge/shaders/`; no LAN TCP listener is opened. `GET identity`
returns the embedded recipe and protocol. `POST close/<request-sha256>` carries
the existing guest adapter's immutable library byte snapshots, origins, preloads
and compile dependency identities. The response binds the request, recipe and
output digest/length, or returns a rejection without executable bytes.

One closure upload/compile/response is admitted at a time. Concurrent uploads
are drained within byte/time bounds and receive HTTP 429. Identity discovery
remains available while LLVM is occupied. The service never reads dependencies
from the host filesystem or accesses guest memory. It returns a macOS-target
library to the guest loader; the ordinary PVG path later performs iOS conversion
on the same serial queue. Neither path invokes an external compiler at runtime.
The host does not retain a second closure cache. The adapter validates and writes
its user cache atomically, namespaced by the discovered recipe.

The default guest path is restricted to Sonoma's unsupported AppleParavirt
Metal device. Native test builds alone allow a loopback endpoint/cache override.
Explicit legacy companion configurations remain supported by their existing
build workflow. This transport does not install the guest adapter or activate it
for normal application launches; those release requirements remain open.

```sh
python3 compat/ondevice-dynamic/build_service_controls.py \
  --provider-archive PROVIDER/lib-macosx/libHGOnDeviceShader.a --output NEW_SERVICE
python3 compat/ondevice-dynamic/qualify_service.py --controls NEW_SERVICE \
  --fixtures NEW_FIXTURES --output NEW_SERVICE_RESULTS
```

These controls exercise the actual Unix HTTP implementation and native API
adapter, with the embedded linker and GPU. They check shared-queue exclusion,
busy responses during a full upload, discovery while busy, coherent requests,
rejections, three cold API cases and warm cache reuse (1536 exact values).
They do not qualify the iPad guest, new Henge binary, background snapshots or
fresh-install automatic delivery.
