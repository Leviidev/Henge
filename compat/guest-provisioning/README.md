# On-device guest provisioning

This directory is an incomplete step toward automatic Sonoma compatibility
installation. No production code currently mounts or modifies a guest disk.

The TrollStore package builds and signs `henge-root-helper` from `root_helper.c`
and adds `com.apple.private.security.no-sandbox` and
`com.apple.private.persona-mgmt` to the app signature. Ordinary IPA packages omit
the helper and these additions. These entitlements and the persona 99 / UID 0 /
GID 0 launch mechanism follow [TrollStore's root-helper documentation](https://github.com/opa334/TrollStore#root-helpers).
The app does not request `platform-application`, which has additional IOKit and
container-access consequences. Whether these permissions suffice in Henge's
application context still requires qualification on the matching iPad.

At launch, Henge runs a read-only `probe-v1` on a background queue. The helper
accepts no paths or other operations. It reports real/effective user and group
identity and whether Apple's image attachment and APFS mount tools are
executable. It never opens a guest image or creates a mountpoint. The launcher
checks all persona setup results, closes unrelated inherited descriptors,
supplies a fixed environment, bounds output to 4095 bytes and kills/reaps a
helper that does not complete within three seconds. Valid root identity is
required before it logs a successful capability report. A failed or absent probe
does not prevent normal VM use.

`python3 -m unittest discover -s tools/compat -p test_root_helper.py -v`
exercises the native launcher with **test-only persona stubs**. It covers protocol
rejection, unsuccessful exit, signals, excessive output, missing/nonexecutable
helpers, denied persona setup, inherited environment/descriptors and timeout
cleanup. These controls do not establish iPad root permissions.

The separate `tools/compat/audit_guest_disk_mount.py` developer control proved
read/write attachment of an authored scratch APFS image on the iPad, including
marker persistence after a read-only remount and detach while holding an inode
lease. It used root SSH, not this application helper. Actual Sonoma Data-volume
selection, encrypted volumes, source-built payload delivery, rollback and guest
activation remain unimplemented. VM disk ownership locking excludes cooperating
concurrent writers; it does not make editing a disk behind suspended guest RAM
safe. Provisioning must not mutate a paused VM's backing image.

## Source-built guest payload

`tools/compat/build_guest_payload.py --output NEW_DIRECTORY` first checks the
embedded compiler archive and its source receipt, then compiles the production
dynamic-library adapter and CGL discovery library for arm64 macOS 14. It does
not build the legacy Mac compiler service or enable native-only test overrides.
The adapter uses private guest-network compiler discovery without a supplied
configuration, token or endpoint. The CGL component retains its existing
process-local activation requirement; bundling it does not solve global discovery.

Packaging runs this build automatically and embeds `henge-guest-payload.tar.gz`
plus a descriptor binding archive hash/size, manifest hash, payload identity and
compiler recipe. Guest Mach-O files stay inside the archive so an iOS package
signer cannot rewrite their signatures. The flat archive contains the two
compatibility dylibs, all nine VLC plugins, their licenses/build receipt, Henge's
GPL-2.0 license and the manifest. Timestamps and archive ownership are normalized.
The manifest includes source hashes, exact file hashes,
sizes, permissions, target architecture and minimum macOS version.

The app signature authenticates the embedded descriptor and archive. The Python
manifest verifier only checks integrity and closed inventories; a self-consistent
external manifest does not authorize installing files. An installer must bind its
input to these resources in the signed app, reject unexpected paths and validate
everything before making any guest change. Payload installation, version
activation, rollback and VLC delivery remain unfinished. Neither the helper nor
the app currently extracts this archive onto the guest.

The VLC plugins are one compatibility unit bound to the exact official 3.0.24
core hash; partial units or other core versions are rejected. Packaging builds
them automatically using the pinned reference/source download cache (override
with `HENGE_VLC_ARCHIVES` or the builder's `--vlc-archives`). Compiled plugins are
never reused from that cache. All plugin signatures, arm64 architecture and VLC
3.0 entry points are checked before embedding. Source hashes are captured before
the build and checked again afterward, so an edit during compilation cannot
produce a falsely bound manifest. VLC itself and its reference frameworks are
not bundled by this payload. Updating an installed app, preserving its data and
signature policy, and checking normal launches remain separate guest gates.
