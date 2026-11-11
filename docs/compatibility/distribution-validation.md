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
