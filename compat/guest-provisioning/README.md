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
accepts no caller paths. It reports real/effective user/group identity, tool
availability and verification of its bundled payload. The additional
`verify-payload-v1` operation reports only the read-only payload check. Neither
of these operations opens a guest image. The launcher
checks all persona setup results, closes unrelated inherited descriptors,
supplies a fixed environment, bounds output to 4095 bytes and kills/reaps a
helper that does not complete within three seconds. Valid root identity and a
verified bundled payload are required for a successful capability report. A failed or absent probe
does not prevent normal VM use.

`python3 -m unittest discover -s tools/compat -p test_root_helper.py -v`
exercises the native launcher with **test-only persona stubs**. It covers protocol
rejection, unsuccessful exit, signals, excessive output, missing/nonexecutable
helpers, denied persona setup, inherited environment/descriptors and timeout
cleanup. These controls do not establish iPad root permissions.

## Native payload boundary

Packaging compiles the descriptor SHA-256, compiler recipe, payload identity and
VLC core/lock identities into the signed helper. The helper finds resources beside
its own canonical executable, never by accepting paths or hashes from its caller.
An unbound developer helper rejects payload verification. The app requires a
successful payload check as well as root identity before reporting readiness.

`HGGuestPayload.m` opens bounded regular resources with `openat`, no-follow and
nonblocking flags, checks their identities, and decodes gzip/tar entirely in
memory. Compressed input is limited to 16 MiB and expansion to 32 MiB. Exactly
the known flat, regular-file inventory is accepted; duplicate/extra/missing names,
paths, links, owners, timestamps, permissions, malformed checksums, padding,
concatenated streams and trailing data are rejected. The descriptor binds the
manifest; target, compiler, complete VLC unit and every member hash/size/mode
must match. No directory, image, mountpoint or guest file is written.

Native authored-fixture controls cover valid inventories, identity changes,
corruption, gzip limits, tar metadata, links, FIFOs, missing members and ABI/profile
changes. The parser also accepted the real 19-member release archive. Neither
these Mac controls nor iPadOS cross-compilation qualify iPad root permissions or
actual guest installation.

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

Signatures alone do not prove loadability. Packaging also uses a separate native
process to load the guest libraries and an isolated signed VLC candidate's own
headless module loader to check all nine plugins. Content-based UUIDs are retained
with reproducible linker mode. These build-time checks do not qualify guest
execution or GUI behavior, and they never start the installed VLC app.

## Read-only image inspection

The internal `henge_root_helper_inspect_disk` API opens a caller-selected,
machine-owned regular file read-only and passes it at fixed child FD 3; no image
path appears in the helper command line. It rejects symlinks and nonregular
resources before spawning. Pipe/image source descriptors are duplicated above
stdio/FD 3, explicitly closed in the child after mapping, and excluded from other
inheritance. The existing fixed environment, root persona and three-second limit
apply. The helper's `inspect-image-v1` requires root and a verified bundled
payload before inspecting the inherited image. It accepts no path arguments.

`HGGuestDisk.c` obtains the descriptor's path, opens an independent read-only
descriptor, matches its inode/size/timestamps before reading, and acquires an
exclusive nonblocking lease. This preserves the incoming descriptor's locks and
excludes cooperating VM readers/writers, including hard-link aliases. It holds
ownership through inspection and closes the lease before the API returns.
Installation must acquire a new lease and revalidate within its own transaction;
this metadata report never reserves or authorizes a later write.

The current profile checks 512-byte-sector GPT primary/backup headers, CRCs,
mirrored bounded entry tables, usable ranges, partition overlap and unique IDs,
and requires one ordinary Apple APFS partition. Unused zero-type entries may
retain stale bytes. It reports partition bounds, not a mounted APFS container or
Sonoma Data-volume identity. Noncooperating file changes are detected by a final
identity check. Unsupported/corrupt/in-use images fail without writing or mounting.

Native controls cover sparse GPT fixtures, locks/aliases, incoming lock
preservation, descriptor authority, corruption, geometry and changed files.
The authored 96 MiB APFS image passed native inspection with an unchanged whole
file hash. This API is ready for the next provisioning step; it is not yet invoked
as an automatic install flow. Physical attachment, verified IOMedia ancestry,
Sonoma Data-volume selection and payload delivery/activation remain unfinished.

## Native existing-media inventory

`HGGuestMedia.m` enumerates IOMedia and follows its disk-image ancestry. It opens
regular no-follow image ancestors and matches device/inode to the leased image;
BSD names, volume labels and `hdik` output do not grant ownership. It validates
bounded device names, registry entry IDs, sizes and typed flags, and releases
registry objects on success and failure. A stale/unresolvable image ancestor,
missing API, failed enumeration or changed image fails closed. Hard-link aliases
are recognized by inode identity. The query never attaches, detaches or mounts.

`inspect-image-v1` now requires this inventory to succeed and be empty. An already
attached image is rejected with status 75. The app transport requires the new
`media_inventory_verified` field in addition to its existing no-write checks.
This is a prerequisite for a later attachment transaction, not an installer.

Five native authored-file/test-only IOKit fixture groups cover aliases, unrelated
media, byte-string ancestors, stale paths, malformed properties, duplicate names,
missing APIs and enumeration bounds. These stubs are not device permission proof.
The native scanner separately identified all four media from a read-only attached
96 MiB scratch image on the iPad and observed an empty inventory after ejection.
The bound production helper rejected that attachment, accepted the image again
after ejection, and the complete image hash was unchanged.

`tools/compat/root_helper_device_control.m` builds a separate developer app-bundle
control using the production app-side launcher. On the matching iPad, running it
as UID 501 with no-sandbox/persona-mgmt started the signed helper as UID/GID 0,
verified all 19 payload files, and inspected the actual 64 GiB Sonoma disk without
attaching, mounting or changing it. The same control rejected the attached scratch
image. This developer jailbreak CLI launch is stronger evidence than persona
stubs, but it does not replace the final UIKit/TrollStore application launch gate.

The inventory now includes an `apfs_metadata` object for each owned media record.
It preserves valid UUID/volume-group UUID, bounded integral RoleValue and strict
boolean encryption/lock properties. Missing properties remain absent; they never
imply an unencrypted, unlocked or Data-role volume. Malformed supplied metadata
rejects inventory. iPadOS exposed these fields on the read-only scratch attachment,
which was ejected after observation. Six native fixture groups passed, including
invalid metadata and absent-field controls; arm64 iPadOS compilation passed.
`hg_guest_media_copy_volume_group` now selects one exact System-role (1) and one
exact Data-role (64) APFS volume from a fresh owned-media inventory while the
caller retains the image lease. It requires distinct volume UUIDs, one matching
nonzero volume-group UUID and leaf media. Combined roles, duplicate candidates,
ambiguous groups and explicit encrypted/locked state fail. Missing encryption
fields remain unknown, reported as `encryption_state_verified=false`; they do not
prevent identity reporting and never authorize a mount or write. Both macOS and
the iPad omit these fields on the authored unencrypted System/Data fixture. A
later mount transaction must independently qualify readable access and safe
write policy; this identity API cannot establish either.
It reports identity only: it neither proves the installed macOS version nor grants
mount/write authority after the lease is released. Native fixtures cover valid
selection and these refusal cases. The roleless iPad scratch image is deliberately
unsupported. Real System/Data device qualification, attachment, mounting and
payload delivery/activation remain unfinished.

The developer `guest_media_control` accepts `--volume-group` to exercise this
identity selector. On the matching iPad, it selected the two members of an authored
4 GiB sparse APFS fixture attached read-only, reported the correct role/group UUIDs,
`encryption_state_verified=false`, and an unchanged image identity. The control
exited before ejection; the first ejection was busy and a subsequent retry
succeeded. No volume was mounted. This qualifies native identity reporting, not
production attachment cleanup, encryption policy, guest version detection or
payload installation.

For an authored System/Data fixture, create the Data volume first and change its
role to D, then add the System volume with `-role S -groupWith <data-device>`.
Adding Data to a preexisting ungrouped System failed with -69624 on the test Mac;
changing an existing ordinary volume to System failed with -69599. Always derive
device identifiers from the newly attached fixture and detach it on every exit;
never apply these creation commands to an existing VM or host volume.

## Native read-only attachment transaction

`HGGuestAttachment` retains a caller-owned `HGGuestDisk` lease throughout attach,
volume identification and ejection. It refuses preexisting attachments. It derives
the source path from the descriptor and checks its inode, then runs fixed
`/usr/sbin/hdik -nomount -drivekey write-protected=true` with a fixed environment,
isolated descriptors and a bounded child lifetime. Tool output grants no device
authority. Fresh IOKit ancestry must identify one correctly sized physical GPT
device and read-only media before volume-group selection succeeds.

Close re-queries ownership and physical registry identity before each ejection,
retries busy devices and verifies that owned inventory is empty. Partial attach
and selection errors attempt the same cleanup. A writable/ambiguous device,
reused device identifier or failed inventory never grants ejection authority;
`attachment-cleanup-required` means the caller must stop rather than boot the VM.
Concurrent source pathname replacement reports `attachment-outcome-unknown`;
the API never guesses device ownership to clean up an unrelated image. This
remaining pathname race requires a stable source path at the integration boundary.

Seven native state-machine controls cover normal closure, existing attachments,
partial failure, unsupported volume groups, timeout kill/reap, busy retries,
persistent cleanup failures, device reuse and repeated open. Subprocess/IOKit
boundaries in these controls are mocked. Separately, the developer native control
attached the authored System/Data fixture on the matching iPad, selected the group,
ejected it and reported unchanged image identity while retaining the lease.
No volume was mounted or written. Production root-helper operations do not invoke
this transaction yet: mount qualification, payload delivery, activation and
fresh-device acceptance remain unfinished.
