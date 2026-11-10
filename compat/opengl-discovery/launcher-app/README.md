# VLC Hardware launcher app

A separate clickable **VLC Hardware.app** starts the existing
`/Applications/VLC.app/Contents/MacOS/VLC` through the reviewed generic OpenGL
discovery launcher. It opens VLC normally, without forced media or playback
options. Use VLC's **File → Open File** afterward.

**Prerequisite:** Henge's matching protocol3 compiler/profile, host vertex and
viewport correction, and validated conversion cache must already be active.
Renderer discovery alone previously produced black video. This wrapper does
not install or enable those fixes and cannot independently verify rendering.
The current paired build passed the device controls; another installation
still needs its own rendering check.

On first use, macOS may ask whether **VLC Hardware** can access a selected
folder such as Downloads. Approve the normal system prompt for files you want
to open. The launcher does not change or bypass macOS privacy permissions.
Use VLC's File → Open File in this session; `open -a VLC` can start a separate
original/fallback process.

Quit existing VLC before opening VLC Hardware. An already running target is
reported rather than terminated. The wrapper uses explicit `--executable`,
which avoids applying the old software-fallback `LSEnvironment` embedded in the
original VLC bundle. That bundle is never edited or re-signed. Opening the
original **VLC.app** remains the existing fallback route. Both routes run the
same VLC binary and share its normal user preferences; the wrapper changes no
VLC preferences, though VLC itself can save settings/history normally.

The wrapper finds its bundled `launch` and `registry-discovery.dylib` through
`NSBundle`, so moving the wrapper or using paths with spaces works. Each run
gets a unique `~/Library/Logs/Henge/OpenGL/<date>-<UUID>/` directory containing
`wrapper.json`, `launcher.log`, and the generic launcher's `receipt.json` and
`target.log` when their stages are reached. The receipt publishes the exact
child PID immediately after launch. The wrapper requests optional activation
of that PID after app readiness; the receipt distinguishes a sent activation
request from observed foreground status. Activation does not unlock the guest
or dismiss file-access dialogs. There are no global environment,
registry, login, or LaunchServices injection settings. The generic launcher
still checks the target signature/restrictions and refuses inherited DYLD
injection. This wrapper does not circumvent those checks.

## Build on an Apple Silicon Mac

First build the reviewed helpers using the parent `opengl-discovery/build.py`,
or select its already validated output directory. This kit does not download
or change VLC.

```sh
python3 build.py --helper-dir /absolute/path/to/opengl-build \
  --output /absolute/path/to/new-wrapper-output
```

The output is a signed `VLC Hardware.app.tar.gz` plus `manifest.json` with
all file/input hashes and the toolchain/build command. The archive contains the
normal app bundle. Build and signing happen in a temporary directory to avoid
Desktop/cloud-file-provider Finder metadata races; only the new wrapper is
ad-hoc signed. Bundled helper bytes retain their original hashes/signatures.
Archive metadata is normalized; two clean builds were byte-identical here.

`--name`, `--bundle-id`, `--target-executable`, and `--target-bundle-id` configure
the app's Info.plist at build time. Empty target bundle ID disables the optional
already-running-app check for ordinary command-line target tests. Normal runs
accept no target override or media arguments.

## Install in the Sonoma guest

Transfer the archive and `install.sh` using the existing authenticated transfer
route. Compare the archive SHA-256 with its manifest, then extract to a new
folder and run the installer. Python or development tools are not needed in
the guest.

```sh
mkdir wrapper-unpacked
/usr/bin/tar -xzf 'VLC Hardware.app.tar.gz' -C wrapper-unpacked
/bin/bash install.sh "$PWD/wrapper-unpacked/VLC Hardware.app"
```

Default destination is `~/Applications/VLC Hardware.app`; an optional second
argument chooses an absolute destination directory. The installer verifies the
wrapper signature, stages a copy, and replaces only a wrapper with the same
Henge marker and bundle ID. A previous matching wrapper is moved intact to a
unique `~/Library/Application Support/Henge/LauncherBackups/<UUID>/` folder.
Any unrelated app at the destination is refused. It never launches VLC,
modifies `/Applications/VLC.app`, removes quarantine, or re-signs the target.

For rollback, quit VLC, move only VLC Hardware.app out of Applications, and
restore the printed previous-wrapper backup if desired. Opening the original
VLC app uses its retained fallback. Run logs are separate and may be removed
when no longer needed.

## Native checks

```sh
python3 test.py --helper-dir /absolute/path/to/opengl-build --output /new/test
python3 test_install.py --archive '/path/VLC Hardware.app.tar.gz' --output /new/install-test
```

Tests use a separately authored target and temporary wrapper copies. They
verify relocated resource resolution, unique preflight receipts, a normal
no-extra-argument launch, unchanged target bytes, installer backup behavior,
signatures, and refusal to replace an unrelated app. They do not open media,
create a GPU context, exercise VLC itself, or qualify iPad rendering. Native
normal-run test logs are archived into the test output, then that test's unique
Library log folder is removed.
