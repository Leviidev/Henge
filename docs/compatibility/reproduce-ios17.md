# Reproducing the Sonoma / iPadOS 17 compatibility changes

This branch separates Henge source fixes from optional guest VLC source patches.
See [source series and review boundaries](patch-series.md) for clean application
and the distinction between the device lineage and current-upstream reconciliation.
It contains no Apple shader libraries, converted shader caches, VM disks, boot
ROMs, credentials, signed apps, or captured user data. Regenerate authored tests
from source and obtain your own macOS inputs. Existing diagnostic programs are
opt-in and do not run during a normal application build.

## Tested baseline and requirements

- Source baseline: Henge `f9c12c93620af4c4c5f5f65f9793b72f883be682`.
- Host: Apple Silicon Mac, Xcode 27.2 build 27B52, iPhoneOS SDK 27.2 build
  24B8118, macOS SDK 27.2, Apple clang 21.0.0 (`clang-2100.4.1.1`),
  xcodegen 2.46.0. These are tested versions, not a claim that older tools work.
- Dependency source: Husk `afe83d45b31194c4cc9f7b3db7ec2c757db8346e`, clean tree.
  Pin that checkout and its source dependencies; do not copy a stranger's
  prebuilt pairing/JIT libraries or provisioning profiles.
- Henge's upstream minimum remains A14/M1 or newer and iOS/iPadOS 17+. This
  compatibility work was tested on an iPad running iPadOS 17.0 (21A329), with
  Sonoma 14.6.1. It does not qualify every device or later OS combination.
- The tested production installation/JIT route is TrollStore on supported
  iPadOS 17.0 with the required entitlements and executable-memory permission.
  The new JIT readiness code requires a held, tested region, not just a debugger
  flag. Developer-provisioned `devicectl` audit apps are a separate diagnostic
  route; they do not establish equivalent Henge GPU/JIT behavior.
- SSH is needed only for the tested deployment/companion workflow: a reachable
  iPad SSH service, a verified host key, operator-owned authentication, Python 3
  on the iPad, and explicit access to the correct Henge application/Documents
  container. No password, private key, device UDID, or fixed LAN address is
  stored in this repository. Configure those locally.
- Keep enough free space for the guest disk, RAM backing if required, build
  products and a known-good IPA backup. Do not copy an unrelated machine's
  ECID, trust state, credentials, or user disk into a public fixture.

## Build from clean source

Use Python 3.9 or later. In a local virtual environment, install the pinned host
diagnostic dependencies with `python3 -m pip install -r requirements-compat.txt`.

Install the host build tools (including CMake, Meson/Ninja, pkg-config and Rust
with `aarch64-apple-ios` for Husk's pairing library). Obtain the pinned Husk
checkout, use its `scripts/fetch_sources.sh`, and build its dependencies with
`scripts/build_ios.sh` and `scripts/build_rppairing_ios.sh`. StikJIT's framework
and its licence/source provenance come from that same pinned checkout. Follow
Husk's own build documentation for its prerequisites.

```sh
export HUSK=/absolute/path/to/pinned/Husk
# Select the tested Xcode installation explicitly if more than one is installed.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ios/scripts/fetch_deps.sh
make test-sonoma-compat
make ios-lib
tools/build_ios_restore.sh
HENGE_IPA_OUTPUT="$PWD/build/artifacts/Henge.tipa" ios/scripts/package_ipa.sh --trollstore
python3 tools/compat/build_manifest.py --husk "$HUSK" --output build/build-inputs.json
python3 tools/compat/external_toolchain.py --llvm-config /path/to/llvm-config \
  --output build/external-toolchain.json
```

`HUSK` now selects both dependency copying and the engine's include sysroot.
`IOS_DEPS` can override that sysroot explicitly. `HENGE_IPA_OUTPUT` controls the
package path; `HENGE_DERIVED_DATA` controls Xcode's build directory. Existing
`HENGE_ENTITLEMENTS` behavior remains. Never add a signing identity or team ID to
tracked project files. Package signing is ad hoc for TrollStore; signing an
ordinary developer install requires your own valid identity/profile.

The manifest records source hashes, compiler executable hashes, SDK build and
all consumed Husk binary hashes. The external-toolchain receipt also records
SDK build identities and exact compiler/LLVM library hashes. It is separate
build provenance: the initial dynamic-library runtime recipe binds tool version
strings, source hashes and policy, but not these external executable hashes.
A future recipe change must receive a new cache identity and its own guest gate;
never relabel an existing cache/kit with stronger provenance. Build paths, timestamps, generated Xcode UUIDs,
and signing can make final IPA bytes differ. This is a reproducible source/build
recipe with input verification, not an unsupported bit-for-bit IPA claim.

## Cloud/FileProvider workspace builds

If Xcode stalls before planning while reading a Desktop/cloud-managed project,
move the entire committed source snapshot outside that managed tree. Moving only
DerivedData did not resolve the observed `NSFileCoordinator` wait. The validated
full builds used fresh `/tmp` source plus dependency/restore builds, one app build
at a time. Do not restart shared Xcode services or stop unrelated processes.

From a clean committed checkout, this preserves the exact source commit and tree:

```sh
set -e
henge_source_root="$PWD"
henge_source_commit=$(git rev-parse HEAD)
henge_source_work=$(mktemp -d /tmp/henge-source.XXXXXX)
mkdir "$henge_source_work/source"
git archive --format=tar --output="$henge_source_work/source.tar" "$henge_source_commit"
tar -xf "$henge_source_work/source.tar" -C "$henge_source_work/source"
git -C "$henge_source_work/source" init
git -C "$henge_source_work/source" fetch --depth=1 "$henge_source_root" "$henge_source_commit"
git -C "$henge_source_work/source" reset --mixed "$henge_source_commit"
shasum -a 256 "$henge_source_work/source.tar"
cd "$henge_source_work/source"
```

Run the same dependency, `make ios-lib`, restore-library and packaging commands
above from that snapshot. Keep `HUSK` explicit, select fresh `/tmp` DerivedData and
write the TIPA/receipts to your private retained output directory. Git metadata
allows the package's embedded build commit to remain exact. Preserve the archive
hash, source commit/tree, dependency manifest and package identity. A cancelled
or stalled build is unqualified; never package a stale earlier app.

## Authored regression assets

```sh
python3 ios/scripts/shader_inventory_device_firstuse_prepare.py build/authored-firstuse \
  --nonce 00000000000000000000000000000042 --bundle-id org.example.henge.shaderaudit
```

This compiles fresh authored basic, packed multi-module, static-link, function
constant and tile inputs for macOS/iOS and generates an unsigned Xcode project.
It no longer needs a copied private project. Use a new nonce to prove a cold
path, and keep the source/asset/recipe hashes with the results. A successful
build does not prove device execution or an uncached conversion route.

`make test-sonoma-compat` runs the pure C/worker controls and Python checks.
Tests that require retained Apple/captured evidence skip explicitly when it is
absent; they are not counted as successful execution of that evidence. For an
operator's own retained corpus, set `HENGE_TEST_ARTIFACTS` to its workspace root.
Do not redistribute that corpus. Source-only display compilation remains
available through `ios/scripts/check_display.sh`.

## Guest and shader setup

Use your own Sonoma 14.6.1 installation. Henge's host engine supports
`hengevm --install IPSW`; the upstream restore/export workflow is documented in
`docs/architecture.md` and `tools/export_ios.sh`. The guest signing server and
restore availability are external requirements; an existing personal guest
must be backed up, not silently replaced to make a test pass.

The current first-use shader companion is explicitly opt-in:

```sh
python3 ios/scripts/shader_companion.py --help
python3 ios/scripts/sync_shader_conversions.py --help
```

Supply your SSH host and the exact application Documents path. The companion
uses a recipe-qualified/hash-checked cache and a short-lived lease. Existing
valid cache entries work offline; uncached conversions currently require the
Mac companion. Generated Apple libraries remain private local data. The separate [dynamic-library package](../../compat/dynamic-libraries/README.md)
has its own explicit compiler/configuration and offline-cache boundary; do not
infer it from this static conversion companion. It is selected-process, stateless
compute only. Its production injected package passed an independent guest cold
transport gate and cached offline controls; those results remain separate from
the precursor and native controls. Cold misses still need the Mac compiler.

## Installation, rollback and health checks

The production route is an in-place TrollStore update over explicitly configured
SSH, or manual import of the same package in TrollStore. Never uninstall Henge
as an update step: that risks the Documents container and guest disks. Retain a
known-good IPA, its hash, the original bundle identity and the exact Documents/
machine paths before replacement. Stop the guest and Henge before replacing the
app; preserve all guest files. The deployment helper follows the tested `trollstorehelper install PACKAGE`
route and discovers TrollStore by its app/helper rather than a fixed container UUID.
It requires the configured remote icli-compatible controller to kill only the
halted Henge app; it never uninstalls it. Model, exact OS/build, bundle/data
container binding and guest storage identity are checked before mutation.

```sh
python3 tools/compat/ipad_update.py preflight --host root@YOUR_VERIFIED_SSH_HOST \
  --bundle-id com.henge.app --data-container /absolute/Henge/data/container \
  --machine-directory /absolute/Henge/data/container/Library/Application\ Support/Machines/YOUR_MACHINE \
  --expected-model YOUR_IPAD_MODEL --expected-os 17.0 --expected-os-build 21A329 \
  --output .compat-local/preflight
python3 tools/compat/ipad_update.py update --plan .compat-local/preflight \
  --package build/artifacts/Henge.tipa --rollback-package /path/to/known-good.tipa \
  --output .compat-local/update-receipt
```

Use your own paths. This generic preflight/update/identity flow passed on the
tested iPad: installer exit0, unchanged disk identity, exact auxiliary hash and
correct normalized installed code. Another target still needs its own preflight
and manual acceptance. `--app-control` and `--host-key-alias` are configurable.
Preflight is read-only. Update saves private candidate/rollback packages and an
auxiliary backup, rechecks the halted state, verifies transferred bytes, performs
an in-place install, and compares normalized executable code despite resigning.
Application-update and data-preservation receipts are separate. Disk preservation
checks device/inode/size/mtime; auxiliary preservation also checks SHA256. This is
not a full disk-content hash. A mismatch stops without overwriting guest data.
For rollback, halt again, make a fresh preflight, and run the same guarded update
with the retained old package as candidate and the current package as rollback.
Do not publish `.compat-local` receipts: they contain device paths and auxiliary data.

`python3 tools/compat/ipad_update.py health --receipt .compat-local/update-receipt
--output .compat-local/health.json` rechecks installed code and target/container
identity without requiring a halted guest. It explicitly leaves visible/manual
acceptance pending.

After an update, verify the package/source identity, that the same data container
and machine files remain, JIT readiness, desktop boot, pointer/scroll input,
wallpaper/lock/unlock, a visible video frame plus actual speaker output, and the
ordinary VLC export path if that optional compatibility package was installed.
A headless successful process alone is not a visible rendering or speaker test.
Rollback reinstalls the retained known-good package under the same bundle ID;
it does not erase the app or restore a stale guest disk over current user data.

## Separate guest compatibility and remaining integration

The optional [VLC source package](../../compat/vlc/README.md) fixes AAC drain,
MP4 timing, default module selection, native HEVC menu and VUI forwarding. It
provides pinned clean builds, authored export controls and guarded normal-app
promotion/rollback. A new build still requires guest GUI and speaker acceptance.

The [OpenGL discovery helper](../../compat/opengl-discovery/README.md) supplies a
missing renderer discovery property only within explicitly launched processes.
With the separately tested late render-store-action fix, accelerated clear/GLSL
and five bounded draw/readback cases passed on the tested Sonoma/iPad route.
System renderer registration is unchanged; ordinary double-click applications
without this opt-in route are not thereby repaired. The [paired protocol3
compiler/viewport integration](profiled-opengl.md) adds independently validated
clip/depth handling. No all-app OpenGL claim is made.

The [AGX provenance journal](agx-journal.md) is opt-in diagnostics. It archives
actually selected bytes and first/retry pipeline attempt metadata without a new
Metal-object retention policy. The historical AGX lock abort remains unproven;
successful later compilation does not retrospectively identify or fix it.

The original-base staging series and latest-upstream reconciliation are separate.
The latter preserves upstream planar aliases, generalized metallib relabel,
multitouch trackpad and ordered GPU teardown. Both pass local compilation/tests;
only the original production lineage has the retained device qualification.
Do not deploy the latest-upstream reconciliation as if its new combinations were
already tested on-device. Keep each optional package and subsequent qualification
as a separate reviewed commit and record the exact base/HEAD in build manifests.
