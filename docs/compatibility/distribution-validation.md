# Distribution validation, 2026-11-11

The full iOS build below used source commit
`74fac144ae42` on `pr/sonoma-autosetup`, reconciled against upstream
`9aa4b6dbe10f23fb937941050b6934f695d20f3d`.
This report is build/native evidence, not device qualification of that binary.
The working iPad installation was not replaced during these packaging checks.

## Compiler and app

- LLVM input: clean `gzorin/floor_llvm` checkout at
  `6a133d69154dfaffa04a6339a3178db328bd98a5`, built through
  `tools/compat/build_ondevice_provider.py` in a new output directory.
- Both native and iOS archives completed. The clean build exposed CMake's iOS
  bundle default; explicitly disabling that default fixed configuration. A second
  complete helper invocation then succeeded without repairing its build directory.
- Provider recipe:
  `aef1c5c999ea60d67fbc24dca672c81578b7ed1522c705e5f30c28ed1efe8dd6`.
- Staged iOS archive SHA-256:
  `d48302b4503261c2f741231d8f51c45516dcfed9e7b34a4c16bf71a58287f71a`.
- Newly generated controls from `tests/build_ondevice_fixtures.py` passed the
  rebuilt `native_provider_tests`: async/coalesced requests, immutable snapshots,
  bounded backpressure, GL profile binding, cache reuse, corruption rejection,
  source identity rejection, invalidation and namespace isolation. Compute output
  matched all 256 expected values. These are authored ABI/coordinate fixtures,
  not captured GLSL frontend output or a universal shader corpus.
- Husk input: clean tracked source at
  `afe83d45b31194c4cc9f7b3db7ec2c757db8346e`, using its existing built iOS dependency
  libraries. Those dependency libraries were not independently rebuilt during
  this packaging pass. CI declares their source build steps.
- `make ios-lib` and `tools/build_ios_restore.sh` succeeded. The complete Xcode
  application and TrollStore package then succeeded. Xcode's iOS SDK environment
  initially leaked into upstream's Mac sample compilation; explicit macOS SDK
  selection fixed the build. All five sample programs and their disk image were
  rebuilt with `SDKROOT` set to the iOS SDK as the positive regression control.
- Package size: 10,481,145 bytes. SHA-256:
  `0e9a833fbfb3e00785c1560202f9a02d1bcd0e543775ed5316153667337bdb5f`.
  Its Info.plist records `74fac144ae42`; its executable contains the expected
  provider recipe; the LLVM license is included; no Apple boot ROM is included.
  This local package is not a released or device-qualified build.

## Other controls

- `make test-sonoma-compat`: 65 tests, 13 skipped; 82 tests, 39 skipped.
  Skips require explicitly supplied optional tools/private inputs and are not
  counted as passing runtime evidence.
- `make test-ordered-replay` and `make test-pvg-ordinary-texture` passed, including
  977 ordinary-texture sanitizer checks and exact merged replay/lifecycle controls.
- `make test-vm-pause test-vm-lifecycle` passed the actual native engine controls:
  lifecycle parking/resume, rapid phase reversals, stop while inactive, counter
  origin, natural exit with a parked secondary, twelve power cycles, failed boots
  and an authored snapshot/resume. No GPU commands from a real guest execute in
  these tiny-ROM controls.
- `make test-pvg-task-lifecycle test-pvg-store-action` passed, including 11 task
  identity checks and actual native Metal store/readback controls.
- `python3 -m unittest discover -s tools/compat -p 'test_*.py'`: 14 tests passed,
  including missing/stale provider receipts, wrong archive, recipe tampering,
  ABI mismatch and missing license rejection.
- Verified net-tree export reproduces the exact Git tree on the recorded upstream
  base, including upstream merge resolutions. Linear export now rejects histories
  whose merge resolutions it would otherwise omit.

The fork accepted source pushes and the upstream draft PR. GitHub's Actions API
reported zero registered fork workflows and returned 404 for dispatch/enable of
the workflow, despite the file existing and Actions being enabled. No hosted CI
success is claimed.

The remaining automatic runtime integration and fresh-install gates are tracked
in [the distribution plan](distribution-plan.md). Historical device results must
not be attributed to this newly reconciled binary.


## Embedded dynamic closure port

The new `compat/ondevice-dynamic` C ABI ports the existing supported stateless
compute closure to the pinned public LLVM reader/linker/writer. It takes only
supplied byte arrays and declared origins, with no Apple tools, subprocess,
network access or filesystem dependency search during execution.

- Direct native Metal execution passed loader-relative, absolute-install-name
  and explicit-preload controls: 768 exact outputs, zero mismatches. Latest
  semantic validation also rejected missing origins, missing loader dependencies,
  missing explicit preloads and an otherwise valid dependency whose container
  export name disagreed with the concrete AIR definition. No library was
  published in those four rejection cases.
- A temporary, normally development-signed audit app ran the same three success
  classes directly on the iPad's Apple M1 GPU under iPadOS 17.0. All 768 outputs
  matched after on-device linking and iOS retargeting, library loading, pipeline
  creation and GPU completion. It used no JIT entitlement or Mac compiler service
  while executing. Build-machine Apple tools only generated the authored fixtures.
- That iPad test preceded the additional export/definition binding guard. The
  guard has native validation; its revised source and the integrated Henge binary
  still require an iPad gate. The audit app was removed after saving its report.
- This is a bounded compute-only Metal 3.1 / AIR 2.6 / MTLB 2.7 profile. It does
  not establish support for arbitrary dynamic libraries, graphics entrypoints,
  mutable dependency state, indirect calls or other input versions.

The provider build now compiles the combined ordinary/dynamic translation unit
once, includes the required public LLVM Linker component and binds both dynamic
source files into its recipe and packaging receipt. CI controls explicitly link
against that combined archive. Those direct controls did not exercise guest transport or automatic activation;
current transport integration is recorded below. Merely packaging the backend
does not complete the no-setup goal.


A fresh pinned-source helper build of the combined provider then completed for
both native macOS and iOS. Its archive-linked dynamic controls passed all 768
values and four rejections; the ordinary provider regression controls also
passed all 256 values. The packaging guard tests now include a stale dynamic
source case (15 tool tests passed).

- Combined provider recipe:
  `1af087fb3802f1f4d64314158cb7f8be8504d5cbe49b836f2d4e1cd262dae85f`.
- Combined iOS provider archive SHA-256:
  `1cb352633a5a034d91beca5d4f3713e8598c9ff3fecc7dc47788a46155d013dd`.
- Full Xcode application/TrollStore package built from `24570ef17eca`:
  10,480,708 bytes, SHA-256
  `e040f34e0d0cf3d7662ea9a28855fbed0e515de50997db30a2ddca36390c6fd4`.
  The expected recipe and LLVM license were present; no Apple boot ROM was
  included. This package was not deployed or guest-qualified on the iPad.

The backend being present in the provider archive does not prove retention or
execution of its currently unused entrypoint in the final app. Guest transport
must call it on the ordinary provider's shared serial queue, bind request/output
identities to the embedded recipe, and pass final-binary device controls.


## Private dynamic transport integration

The iOS sharing bridge now automatically registers the embedded shader service
on the existing guest-only Unix-socket network path. The loaded guest adapter
uses automatic recipe discovery and user cache namespacing without a Mac address,
token or configuration file. Explicit legacy configurations retain their workflow.
Both conversion paths use the same process-wide LLVM queue. The service returns
a macOS-target closure to the guest; subsequent ordinary PVG conversion targets
iOS. Guest delivery/application activation remain separate implementation work.

The first native HTTP control exposed a real failure: rejecting a concurrent
upload before draining its body produced a broken pipe rather than an observable
busy response. Bounded draining corrected it. The revised real Unix HTTP controls
passed full-upload backpressure, identity discovery while the compiler queue was
held, queued completion, target preservation, recipe/source/request identity
rejection, missing origins/preloads/compile identities, malformed inventory,
nonlocal origins, oversize upload rejection and an explicit compile dependency.

The native API adapter then used that same service through a test-only loopback
bridge. Loader-relative, absolute-install-name and explicit-preload cases each
produced 256 exact GPU values cold and on a second application launch: 1536 values
total, zero mismatches. The cold phase submitted three compiler requests; the warm
phase submitted none. Paths containing spaces exercised origin normalization.
No Apple compiler was invoked while these controls executed. Their newly authored
fixtures were generated by build-machine Apple tools beforehand.

These controls do not establish new-binary iPad execution, automatic adapter
installation/activation or fresh-guest acceptance. The prototype iPad report above
predates this transport, and must not be presented as transport qualification.


A fresh pinned-source build of this transport/provider revision completed for
both native macOS and iOS. The same transport/API/GPU suite passed against that
exact rebuilt archive, including chunked uploads, a measured 15-second stalled
upload deadline and admission after the timeout. The direct dynamic controls
(768 exact values, four semantic rejections) and ordinary provider controls
(256 exact values) passed against it too.

- Embedded provider recipe:
  `b91b213a40a2540f9e15146ae2f37092b33f09b329f9c550abe70ef41c9e0aad`.
- iOS archive SHA-256:
  `a7fdc7401a0382721ec1e73b809b40b6891caf2ca68f0bb8ed02717fa358340b`.
- Full Xcode/TrollStore app from `ed6e2dfdcbb2`: 10,576,075 bytes, SHA-256
  `cf75c46a34c43311252e055789efc2def699676e18af1627b4729111776b5c9e`.
  The final executable retains `HGOnDeviceDynamicService`,
  `HGStatelessMetallibCloseRequired` and `HGOnDeviceCompilerQueue`; the expected
  recipe and LLVM license are included. The native test endpoint override and
  Apple boot ROMs are absent. This app was not installed on the iPad.
- Compatibility checks remained green: 65 tests/13 skips, 82 tests/39 skips and
  16 packaging/tool tests. Native VM phase/pause controls and 12-cycle lifecycle,
  failed-boot and snapshot controls passed; they execute no guest GPU commands.

Automatic guest delivery/activation and final-binary iPad/fresh-guest acceptance
are still required. Their absence cannot be replaced by these native controls.


## Offline guest provisioning foundation

An on-iPad control established a filesystem route that does not type commands
into the guest. It used only an authored empty 96 MiB GPT/APFS image, created by
the build Mac and copied to the test iPad. No running guest image was attached.
The initial mount under the temporary folder failed. Mounting below
`/private/var/mnt` succeeded, consistent with the
[Dopamine maintainer's mountpoint restriction](https://github.com/opa334/Dopamine/issues/595).
A writable attachment additionally requires `hdik -drivekey write-protected=false`;
without it, the media are explicitly read-only even for a writable raw image.

The tracked developer control `tools/compat/audit_guest_disk_mount.py` then passed
on the iPad. It holds a nonblocking exclusive inode lock for the whole operation,
checks the actual IOMedia image-path ancestry, writable state and physical size,
mounts with `noexec,nosuid`, writes and synchronizes an authored marker, unmounts,
remounts read-only and verifies the marker. It finally unmounts and ejects the
owned attachment. The report observed both marker roundtrip and complete cleanup.
The tool requires an explicitly named 96 MiB scratch fixture and never reformats
an image. Python/SSH were developer instrumentation, not a completed application
bootstrap or a requirement to impose on users.

`host/disk.c` now holds the matching inode ownership lock while a VM has an image
open, including during pause/snapshot. Writable opens are exclusive; read-only
opens share ownership but still exclude a provisioner. Lock conflicts fail
immediately with a specific VM error. Both disk descriptors close on exec, and
an alternate uncached writer must match the locked inode and close before the
ownership descriptor. This prevents helper execution from retaining an old disk
lease after shutdown.

All 18 native ownership controls passed, covering hard-link aliases, competing
VM/provisioning opens, shared readers, inherited descriptors, exec cleanup,
invalid-offset cleanup, uncached writes and release. The iOS engine build and
native VM phase/pause/lifecycle/snapshot controls also passed. This does not
qualify the final app's device path or a mount of the actual Sonoma Data volume.

Remaining production requirements include qualified root-helper execution and a
source-built guest payload, normal-app activation, identification of the owned
Sonoma Data volume, backup-preserving atomic version changes and a device gate.
[TrollStore documents the root-helper/persona mechanism](https://github.com/opa334/TrollStore#root-helpers),
but that mechanism has not yet been qualified in this Henge build. Provisioning
must first inspect read-only, avoid mounted/live guest state, and never change a
suspended guest's disk beneath its saved RAM. An already-current payload must
leave disk identity unchanged so ordinary snapshot resume stays valid. No global
DYLD injection, app re-signing or security-policy change is established by the
scratch mount result.


The full native bridge also rejected two deliberately busy-image boots (root disk
and auxiliary storage), reported the ownership conflict and returned to a
retryable idle state without descriptor or worker leaks. Its remaining 12-cycle,
missing-ROM and snapshot controls passed. The DISCARD control was updated to stop
its writable workers and release ownership before reopening the same fixture
read-only; all 1647 checks passed. Compatibility Python checks remained at
65 tests/13 skips, 82 tests/39 skips and 16 packaging/tool tests.

### Bundled root-helper capability probe

The TrollStore packaging path now compiles and signs a native helper from
`compat/guest-provisioning/root_helper.c`. It accepts only `probe-v1`, reports
real/effective root identity and tool availability, and never accesses a guest
disk. Henge starts this check on a background queue using persona attributes,
with a fixed environment, unrelated descriptors closed, bounded output and a
three-second completion deadline. Ordinary IPA packaging omits the helper and
the new unsandbox/persona entitlements.

Both the helper and Objective-C launcher compiled for arm64 iPadOS 17 with
warnings treated as errors. Seven native test methods passed, including valid
and malformed reports, persona denial, abnormal exit, output overflow,
environment/descriptor isolation and timeout reaping. The native controls use
test-only persona stubs: they do not establish actual root permission. The iPad
was unavailable during these checks, so this new helper has not been installed
or run there. This is a capability check, not automatic guest provisioning.

### Source-built passive guest payload

The package builder now compiles the production dynamic-library adapter and CGL
discovery dylib for arm64 macOS 14, after verifying the embedded provider's recipe
and source receipt. It bundles these, their manifest and Henge's GPL-2.0 license
as a flat, normalized archive, with an app-signed descriptor binding archive and
manifest hashes. Guest code remains opaque to iOS package signers. It does not
start or include the legacy Mac compiler service. Production output excludes the
native-only endpoint override, and both dylib signatures pass strict verification.

Two independent builds produced identical payload identities and dylib hashes.
Seven integrity controls passed, covering bytes/size/mode changes, missing or
extra inventory, symlinks/directories, source inventory, recipe/target changes,
unexpected manifest install paths and normalized archive contents. These checks
establish integrity, not the authenticity of arbitrary external manifests; the
signed app's resources are the trust anchor. Delivery to Sonoma, automatic normal
application activation and VLC packaging remain incomplete, and this payload
has not yet run in the iPad's guest.
