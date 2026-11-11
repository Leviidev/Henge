# On-device guest provisioning

This directory is an incomplete step toward automatic Sonoma compatibility
installation. No production code currently mounts or modifies an original guest disk.

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

After a successful startup probe, the app also requests the discard-only private
workspace sweep described below. That operation uses a fixed root-owned
namespace and never opens the original guest image.

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

### Read-only mount qualification (not enabled for automatic startup)

The native transaction can now create private temporary mount directories and
mount the freshly selected System/Data media with `rdonly,nobrowse,noexec,nosuid`.
It checks APFS filesystem type, exact source device and mount path, and required
read-only/noexec/nosuid flags. Close revalidates registry ownership, unmounts Data
then System without force, verifies the original directory inode and removes the
temporary directories before ejection. Unknown mount identity or flags stop
cleanup rather than unmounting an unrelated filesystem. The caller must call
close after mount failure as well as success.

Twelve native mocked-boundary controls pass, including successful dual mounts,
second-mount failure cleanup, and refusal to unmount unexpected/writable mounts.
arm64 iPadOS compilation passes. The first physical mount test on the authored
System/Data fixture did not return within 50 seconds; SSH subsequently refused
connections and Xcode reported the iPad unavailable. A restart/panic is not yet
confirmed, and no panic report has been collected. This is a failed device gate,
not a successful mount qualification. Do not invoke this mount path in production
startup until the device failure is understood and resolved. No production helper
operation currently calls it; the explicit developer control flag is
`--mount-readonly`. No existing guest disk was used in this test.

Review after that failure found an unbounded blocking `waitpid` after SIGKILL in
the tool runner. It now polls for at most one additional second after the normal
three-second timeout, retaining any unreaped child PID. A pending attach/mount/eject
child returns `attachment-command-still-running`; close will not query filesystems,
unmount or eject while that child remains active. A later close can reap it and
clean up once it exits. Native controls cover an unkillable attach child, an
unkillable mount child and a child that exits later. This bounds child waiting;
it does not prove kernel operations cannot hang or explain the physical failure.
Production integration still needs supervision that preserves transaction
ownership for unfinished children and must not boot a VM while cleanup is pending.

### Guest OS identity

`hg_guest_attachment_copy_system_version` reads `SystemVersion.plist` through the
verified read-only System mount. It rechecks registry ownership, validates the
opened root filesystem, traverses fixed directory components using no-follow
descriptor-relative opens, and refuses filesystem crossings. The final regular
file must be at most 64 KiB. It accepts XML/binary plists with bounded, typed macOS
version/build fields and reports `sonoma=true` only for major version 14. A valid
Sequoia version reports false; reporting an OS identity does not grant payload
compatibility or installation authority. No guest file is written.

Fourteen native mocked-boundary test groups now pass, including version parsing,
Sequoia distinction, malformed/type/bounds checks, symlink refusal and filesystem
crossing refusal. The developer control's `--system-version` flag exercises mounts
and OS identification, but has not been run on the device. It remains subject to
the unresolved physical mount gate above; do not run it before collecting logs
and understanding that failure.

### Verified payload staging

`hg_guest_payload_stage_directory` validates the signed-build-bound descriptor,
archive and complete file inventory once, retains those verified member bytes,
and stages under an already opened trusted parent directory. The parent must be
owned by the effective user and not writable by group/other. Creation uses a
private randomized directory and exclusive no-follow file opens, fixed archive
member names, exact modes, file sync, byte-for-byte readback and directory sync.
Only then does an exclusive atomic rename publish the payload-ID-named version;
it never replaces an existing version. Parent sync completes publication.

An existing version is reused only after complete inventory/content/mode/owner
verification, including rejection of symlinks and multiply linked files. A
conflicting version is preserved and reported. Failure cleans only this call's
owned temporary directory; an unexpected cleanup obstacle is reported rather
than recursively deleting unknown data. Stages left by a terminated earlier
process are never mistaken for a published payload and are not silently removed.
The report distinguishes publication, durable success, reuse and cleanup status.

Nineteen native parser/staging fixture groups pass, including partial-write fault
injection, conflicting files, unsafe destinations, interrupted stages and exact
reuse. arm64 iPadOS compilation passes. These tests use host directories and do
not qualify writes to guest APFS mounts. No production helper command invokes
staging yet. This API does not activate code or choose guest paths, and it does
not grant disk-lease/mount authority. Writable mounting, guest path policy,
activation/rollback, VLC integration and end-to-end acceptance remain unfinished.

### Confirmed iPadOS mount policy failure

After jailbreak access returned, the device panic report confirmed the physical
mount attempt caused `unencrypted data volume is not allowed` in
`apfs_vfsops.c:2261`, with `mount_apfs` as the panicked task on iPadOS 17.0. This
is a kernel policy failure; longer timeouts or different retry behavior cannot
make this mount profile valid. The earlier roleless scratch-volume mount did not
exercise this Data-role restriction.

The mount API now rejects iOS-family calls with
`ios-volume-group-mount-unsupported` before querying media or invoking a mount
tool. Fifteen native control groups pass, including a forced-iOS policy control.
A separately signed native control on the iPad confirmed this refusal without
accessing an image or invoking a mount. The old developer mount executable was
removed. Root-helper production commands still do not invoke mounting.

An alternate on-device provisioning path is required. A host copy-on-write clone
of the authored fixture was created, but ordinary `diskutil` role clearing was
refused with -69599. The `0` role argument is a no-op, not a role reset; a command
returning success for `0` is not evidence of neutralization. No guest disk role
was changed, and no clone workaround has been qualified on iPad. Do not remove the iOS
guard based on host mocks or the old roleless scratch test.

### Alternate path investigation: isolated clone and bounded APFS identities

A host-only authored-fixture experiment now demonstrates a possible alternative:
clone the image with APFS copy-on-write, neutralize the copied Data role, stage the
real 19-file compatibility payload, then restore the role before publication. The
original image's full SHA-256 remained unchanged. A role-only round trip reproduced
its original bytes exactly. After actual marker/payload writes, role restoration
preserved the volume group and both volume UUIDs; the host APFS checker passed,
the marker matched and the native stager reverified all payload files and modes.
No guest image was used. This is not iPad qualification or production installation.

The experiment's metadata scan is unsuitable for production writes: file contents
can resemble filesystem metadata, and historical checkpoints need an explicit
policy. `HGGuestAPFS` therefore adds a separate read-only native inspector. It
uses the existing exclusive image lease, validates container/object checksums,
selects the latest checkpoint and traverses bounded container object-map B-trees
to resolve each volume superblock. It reports role, volume/group UUID, flags,
object/transaction identity and physical block without scanning file contents,
attaching or mounting. It rejects ambiguous same-transaction checkpoints, cycles,
bad offsets/mappings and changed image identity. The current format profile requires
the ordinary version-2 container layout, bounded descriptor arrays, fixed-size
object-map records and at most 100 volumes; unsupported formats fail closed.

The initial seven native groups passed with address/undefined-behavior sanitizers,
including interior-node traversal, corruption at every metadata layer and bounds
refusal. On the real authored fixtures, it independently resolved the original
roles and the newer Data superblock after payload writes/restoration. arm64 iPadOS
compilation passes. `hg_guest_apfs_inspect` reports only the latest checkpoint and does
not authorize a role rewrite, checkpoint rollback, clone publication or mounting.
A complete mutation/rollback policy for recoverable checkpoints, interrupted writes,
clone ownership/publication and device acceptance is still required. The iOS
mount guard remains in place.

Layout reference: [Apple File System Reference](https://developer.apple.com/support/downloads/Apple-File-System-Reference.pdf).

`hg_guest_apfs_copy_catalog` additionally resolves every distinct NX checkpoint
present in the bounded descriptor area. It preserves historical role/UUID/group
records, deduplicates physical superblocks and records the checkpoint range that
references each one. Exact duplicate checkpoints are counted once. Initial empty
container checkpoints contribute no volume references; an unresolvable populated
checkpoint fails the entire catalog, even if the latest checkpoint is valid.
No older candidate is silently ignored. Reads are limited to a fixed byte budget;
checkpoint and record counts are bounded. The returned catalog is caller-freed.

Twelve native sanitizer-backed groups now pass, including empty/duplicate/shared
checkpoints, historical role changes, conflicts in older transactions and refusal
of unresolved older references. The authored post-install fixture resolves 16
checkpoints and 14 distinct volume records. A separate host-only clone experiment
neutralized all System/Data records identified by the original seven-checkpoint
catalog, without scanning file contents; the resulting copy passed the host APFS
checker. This catalog still does not grant rewrite or mount authority. Production
clone ownership, mutation journaling, restoration after filesystem writes,
publication/rollback and device acceptance remain unfinished; the iOS guard stays.

### Native private COW lifecycle

`HGGuestClone` creates a temporary copy directly from the held source descriptor
using `fclonefileat`; it never reopens the source pathname and has no full-copy
fallback. The caller retains the source lease. The destination is an already
opened trusted private directory owned by the effective user, and the clone name
is generated internally. The new inode has mode 0600 and its own read-only,
close-on-exec exclusive lease. GPT/disk identity and source stability are checked
before returning. It never patches roles, mounts, stages payloads or replaces the
source image.

Discard verifies the original created inode at the owned name and requires fresh
empty IOMedia inventory before unlinking it. A substituted path, attached media or
unavailable inventory retains the clone state for retry. Cleanup removes only
the owned copy, synchronizes its directory and preserves borrowed descriptors
and the source lease. Changes to the source invalidate later publication but do
not prevent discarding the independently owned copy.

Nine native sanitizer-backed controls use real Darwin descriptor-based COW and
file leases, with the IOMedia boundary stubbed. They cover independent byte
identity, private modes, locks, source/copy isolation, nonce collisions, handle
reuse, replaced names (including replacement during inventory) and inventory
refusal/retry. A separate native control on
the real authored 4 GiB APFS image used the production IOMedia scanner and passed
create, independent inode/APFS identity, empty-media discard and unchanged source
identity. arm64 iPadOS compilation passes. This is host qualification, not an
iPad clone/mount or production replacement transaction; native role mutation,
journaling/restoration, publication/rollback and activation remain unfinished.

### Role restoration planning

`HGGuestRoles` produces a bounded edit plan from retained original and observed
strict catalogs. Neutralization targets only System/Data roles. Restoration
preserves each historical record's original role; new checkpoint records inherit
the current original volume's role only when OID, volume UUID and group UUID
match. Unknown volumes, conflicting roles, duplicate current identities, invalid
catalog bounds and changes to an old record's flags are rejected. Exact old
records accept their original or neutral role, permitting a partially restored
plan to be planned again without changing already restored roles.

This is pure planning: it never opens or modifies an image. Eighteen native
sanitizer-backed controls cover historical role preservation, newly created
checkpoints, idempotence and conflicting identities. An executor still needs
private clone write authority, full block/checksum revalidation, durable recovery
journaling, media exclusion and publication/rollback. The planner is compiled
into the packaged helper but has no production command or mount authority.

`tools/compat/guest_roles_control.c` opens two authored images read-only under
independent leases, checks matching GPT disk identity/geometry, obtains strict
catalogs and reports the plan without executing it. The real authored original
and role-neutral copy produced four restoration edits. A separate control used
the real post-write catalog with modeled neutral roles to verify restoration of
new checkpoints; that control is not a filesystem-write or recovery proof.

### Journaled private-copy role writes

`HGGuestRoleWrite` obtains fresh source/copy catalogs and computes the plan
internally. It accepts only the independently owned private clone inode under
the retained source lease, with no attached media. Each candidate block must
match its checksum, type, OID/XID, UUIDs, flags and expected role. The only changed
bytes are the role and recalculated Fletcher64 checksum.

Before touching image blocks it creates an exclusive mode-0600 journal in the
private workspace, recording clone identity/geometry and each offset with both
full block versions. Journal memory/storage is bounded to 32 MiB. It synchronizes
the journal and directory, reads back the complete journal, and rechecks image
stability and media exclusion. Each original block is checked again immediately
before writing. Image writes are synchronized and read back; source stability
and private inode identity must still hold on completion.

Any failure once journal creation succeeds permanently taints that in-memory
clone handle. Further role writes refuse it; the safe action is to discard the
copy. Never mount/publish a tainted copy or replay old full blocks over newer
filesystem metadata. Journals are deliberately retained on success and failure:
the enclosing transaction must implement identity-bound restart cleanup and
remove only its own records after the copy has been discarded or committed.
There is no journal replay, restart recovery or publication API yet.

Six native sanitizer-backed test groups cover exact journal contents, byte-exact
role roundtrip, busy media before/after journaling, journal sync/corruption,
partial/torn writes, image sync and readback failures. Inventory is stubbed in
these fault controls. A separate authored 4 GiB image control with the production
IOMedia scanner passed four-block neutralization/restoration, byte-exact full
image comparison, owned discard and unchanged source identity without mounting.
That no-mount roundtrip alone does not qualify mounted writes/new checkpoints or
iPad execution; the separate host mounted-write control is described below. The
primitive is packaged in the helper but has no production command; activation,
restart recovery, replacement rollback and the iOS mount gate remain unfinished.

The developer control's optional `--external-write` mode pauses after
neutralization and restoration, prints the private copy path, and accepts `GO`
only after external tools have detached it. Restoration is run again to check
idempotence, including newly created checkpoints whose roles are already restored.
Normal mode still performs the byte-exact roundtrip without external tools.

A host-only `--external-write-unlocked` variant releases the *copy* lease during
these pauses and reacquires it nonblocking before native restoration. This is
needed because host `hdiutil` refuses an exclusively leased image; direct `hdik`
requires root. The source lease remains held. This variant must never be used by
production provisioning and does not qualify iPad attachment under a held lease.

On the authored 4 GiB fixture this host control staged the real 19-file payload
and a synchronized marker on the mounted neutral copy, detached it, restored
seven records using the native writer, and remounted Data read-only with its
original Data role. Marker bytes and all payload members/modes reverified;
macOS volume verification passed. Repeated native restoration performed no
further edits. The copy was discarded with empty media inventory and source
identity unchanged. This qualifies host mounted-write restoration, with the
explicit copy-lease accommodation above; it is not iPad or publication proof.

### Discard-only recovery of unpublished workspaces

`HGGuestWorkspace` creates an exclusive private directory beneath an already
trusted helper-private parent. Both directories must be owned by the effective
UID, exclude group/other mode access and have no extended ACL. A fixed 96-byte
ownership receipt binds the workspace's device/inode and the protected source
inode, size, APFS bounds and GPT UUID; it contains no caller/source path. The
receipt and both directories are synchronized before the API returns a usable
workspace. No clone, journal or mount may be created before that success.

After process death, reopening checks the exact workspace name, private directory
identity, receipt integrity/ownership and an exclusive workspace lease. Recovery
is discard-only, with a closed namespace of at most 128 entries: one internally
named clone and its role journals. Trust in the private, exclusively
helper-managed directory authorizes cleanup even if the creator died before
recording a new artifact's individual inode. It does not authorize cleanup in an
app-controlled or shared directory. Unknown names/types, hardlinks, source inode,
foreign filesystem, conflicting clone names and excessive inventories are
preserved. A substituted directory cannot reuse the original receipt.

All files are opened without following links, checked against their named inode,
and exclusively leased before any deletion. A copy needs verified empty fresh
IOMedia inventory. Recovery then revalidates all inodes and namespace membership
after that query, deletes only the preflighted copy/journals, and syncs cleanup
before removing the receipt and empty directory. Busy or unavailable inventory
stops all deletion; unknown entries are never recursively removed. Sync failures
retain the live recovery handle for retry, including after directory removal.

The copy may have torn APFS metadata or an incomplete journal: cleanup never
parses/replays those blocks, mounts the image, opens the source or publishes a
disk. Source inode protection also refuses a source moved into the workspace.
Unreceipted/invalid directories are preserved. Creation failure before a durable
receipt can leave a small metadata-only directory, but no heavy artifacts may
exist at that point. The startup sweep below reports incomplete bootstrap
directories as retained; it never guesses that invalid ownership data is ours.

Nineteen native sanitizer-backed cross-process controls cover abrupt exit,
neutralized and torn copies, partial journals, orphan journals, source inode
protection, busy/unavailable media, live leases, path replacement, late namespace
insertion, receipt transplant/corruption, namespace bounds, ACLs and sync retry.
The inventory boundary is stubbed there. A separate control using the production
scanner created and neutralized an authored 4 GiB copy, exited without cleanup,
then recovered it and its journal from another process. The original full source
SHA-256 remained unchanged and no mounting/replay occurred. These are host
controls, not device/root-helper startup or publication qualification.

### Bounded startup recovery integration

`hg_guest_workspace_sweep` inventories at most 256 parent entries before any
cleanup. It reopens only exact workspace names with the same inode observed in
that inventory, then invokes the discard-only recovery API. Live workspaces,
invalid receipts, unknown entries and changed names remain untouched and are
reported separately. A successful bounded sweep does not imply complete cleanup:
`cleanup_complete` is false whenever anything was busy, retained, changed or
ignored. An oversized inventory fails before deleting anything. The final parent
directory sync is required before success.

The root helper exposes `recover-workspaces-v1` after verifying its bound payload
and root identity. It accepts no path or inherited image descriptor and uses only
`/var/db/henge-guest-provisioning-v1`. Recovery does not create that namespace;
absence is a successful empty sweep. A present directory must meet the same
private root-ownership and no-ACL contract. The app invokes this command on its
utility queue after the startup probe. Ordinary packages omit the helper.
Retained data is logged; no force-cleanup, mounting or original disk access is
performed. Native transport checks bounded integral counters, counter totals,
cleanup status and explicit original-disk/mount refusals in the report.

Twenty-six sanitizer-backed workspace test groups include multiple abandoned
copies, live-workspace coexistence, unknown/bootstrap/symlink preservation,
inventory bounds and pending media. Eleven root-helper process groups include
recovery protocol/count failures, fixed command/no inherited image FD and
unbound-payload refusal. Persona stubs do not prove device root access. Full app
packaging and physical root-helper startup remain separate qualification gates;
automatic guest installation, activation and publication are still incomplete.

### Explicit write authority and immutable publication intent

`HGGuestWriteAuthority` requires a caller-opened `O_RDWR` witness for the exact
leased source inode. It never upgrades a read-only input or opens the source for
writing. The trusted transport must attest the caller UID; a request-supplied UID
is not acceptable. Both source and its parent must belong to that principal.
The transport must also establish the app's namespace rights; UNIX ownership
does not attest sandbox permission. The intended TrollStore app is signed with
no-sandbox, but its actual caller identity/rights still need a qualified bridge.
The parent must permit owner write/search, exclude group/other write, and have no
extended ACL or special flags. The single-link source must also have ordinary
flags and no ACL. A world-writable victim file alone cannot grant root rename
authority over another owner's directory. The existing source lease, independent
close-on-exec witness/parent descriptors and exact parent/name binding are
revalidated; later contents, permissions, ACL or namespace changes invalidate
the authority. Borrowed descriptors and their offsets are preserved.

`HGGuestPublicationIntent` writes a fixed, exclusive, mode-0600 `publication`
record before any metadata handoff or exchange. Creation requires that write
authority, a revalidated private workspace/source receipt, unchanged leased
source/copy, complete role restoration and empty media on both images. The
record binds workspace/target-parent/original/copy inode identities, source/copy
names, original metadata and a trusted build payload ID. It is synchronized with
its directory, read back and reopened read-only. Source disk contents are never
written by this API. The record itself does not prove activation or authorize
publication.

Restart inspection reopens the verified workspace and immutable record. Given an
opened target-parent descriptor, it classifies the two retained directory entries
as original-active or copy-active, rejecting unknown inode pairs. It accepts no
source path from the record. This classification is evidence of rename position
only, not content integrity, media exclusion, permission to exchange/delete or
successful guest boot. Generic workspace recovery refuses the `publication`
entry, preserving both files even for an incomplete/corrupt record. Closing an
intent never deletes it or either image.

Eleven native sanitizer groups cover explicit witness/principal binding,
namespace permissions, aliases, ACLs, late changes and borrowed FD preservation.
Eight intent groups cover process-exit reopen, authored-fixture atomic
exchange/swap-back classification, unknown pairs, unrestored/tainted copies,
busy media, sync/readback failure and generic cleanup preservation. Principal
identity is test-supplied there, not proof of kernel caller attestation.

A separate production-scanner host control used a COW copy of the authored
4 GiB fixture, reopened its intent in separate processes before/after an explicit
test-only atomic exchange and swap-back, and verified the original full SHA-256.
Generic cleanup preserved both files. The intent API itself performs no exchange.
There is still no production publication command, attested write-bearing app
transport, ownership handoff/exchange supervisor, restart rollback, health/commit
policy or snapshot invalidation integration. These must be implemented and
qualified before any original guest disk mutation is enabled.

### Parent-app identity qualification

`HGGuestPeer` qualifies the helper's actual live parent, never a PID/UID supplied
in a request. It samples kernel credentials, process start time, executable path
and CDHash before and after. Real/effective/saved UIDs must agree, the parent must
remain live, and its main executable must match the held read-only file opened
from the helper's own bundle. `HGGuestCodeIdentity` verifies the kernel CDHash
against a bounded thin 64-bit executable's SHA-256 CodeDirectory and hashes every
covered 4/16 KiB code page. File identity/timestamps are rechecked. Signature
objects/ranges are bounded; reserved bytes inside the declared signature area
are not executable code. External resource seals/dependencies are not attested
by this primitive.

The kernel entitlement blob must contain Boolean
`com.apple.private.security.no-sandbox=true`; missing, false, integer/string,
malformed or unavailable values fail. Credentials, start time, executable or
CDHash changes also fail and clear the output. Debugged JIT parents are permitted
by the same kernel signature-state profile as the iOS kernel entitlement query.
Read-only codesign queries use the direct syscall, matching the existing Henge
JIT guard, because a jailbreak libc wrapper may hide debugged state. ABI behavior
is referenced against [Apple's iOS 17 XNU process/codesign implementation](https://github.com/apple-oss-distributions/xnu/blob/xnu-10002.1.13/bsd/kern/kern_proc.c)
and [CodeDirectory layout](https://github.com/apple-oss-distributions/xnu/blob/xnu-10002.1.13/osfmk/kern/cs_blobs.h).

The new `attest-caller-v1` root-helper diagnostic accepts no PID/path/image FD.
It opens only sibling `Henge` from its canonical bundle and reports verified
caller UID/PID without reading any guest disk. The app logs the result after its
startup probe; failure does not block ordinary VM use. A successful diagnostic
is not a transferable write capability. Each future mutation operation must
reattest its own live parent and independently establish per-target sandbox
policy, DAC/ACL rights and the explicit write witness.

Nine sanitizer-backed signed-file groups verify real CodeDirectories/pages,
covered-byte tampering, malformed ranges/profiles, unsupported input and FD
preservation. Seven peer groups include process/entitlement boundary stubs for
positive and failure cases, plus a real signed ordinary parent that passes the
kernel UID/path/code checks and is refused for missing no-sandbox entitlement.
Twelve root-helper process groups cover diagnostic protocol/type failures,
unbound input and no inherited image descriptor. A Mac control signed with the
private no-sandbox entitlement was killed at launch, so there is no positive host
qualification of the actual iPad policy. Full positive app/root/device identity
qualification, write-bearing transport, namespace policy and publication remain
separate unfinished gates; original guest writes remain disabled.

### Explicit app-opened write capability transport

`henge_root_helper_check_write_authority` opens independent O_RDONLY and
O_RDWR descriptors in the app and passes them as fixed helper FDs 3 and 4.
It transmits no source path, UID or PID in arguments or environment. Both
must identify the same regular inode; symlinks/nonregular inputs are refused
before spawn. The helper verifies its actual parent, acquires an independent
read-only exclusive disk lease, binds the write witness to that leased inode,
checks the attested owner's file/parent DAC and ACL policy, requires a fresh
empty IOMedia inventory, then reattests the caller and revalidates the authority.
The root helper never opens the original image for writing.

`check-write-authority-v1` is a qualification operation, not an installation:
it does not write, clone, attach, mount or publish anything. Its descriptors
and lease close before return. A returned report is not a capability token;
a provisioning operation must perform and retain these checks itself. This
operation is not invoked automatically during boot or while a VM is running.
Fourteen helper process groups cover fixed-FD access modes/inode identity,
malformed reports, isolated environment/descriptors, and invalid input paths;
eleven native write-authority groups separately exercise namespace policy.
The process test uses persona/helper stubs and does not qualify iPad root or
privileged caller behavior. The physical privileged launch, role-neutral
mount, installation and publication/rollback supervisor remain incomplete.

### Private-copy ownership handoff

`HGGuestPublicationMetadata` performs the copy-only metadata phase after an
immutable publication intent is durable. It requires the original-active inode
pair, retained source write authority, an unchanged/untainted leased copy and
fresh empty media inventories. It sets the private copy to the original owner's
UID/GID/mode and synchronizes/read-backs the result; an abandoned successful
handoff can restore helper ownership and mode 0600. The original file's bytes
and metadata are never changed. The copy stays inside its private directory.
Every failure after the first metadata syscall permanently taints that copy;
its publication record and both images remain available for dedicated recovery.

Twelve native ASan/UBSan intent/metadata groups cover ownership-mode handoff,
restoration, repeat handoff, media refusal and injected chown/chmod/fsync failure,
alongside durable intent and inode-pair controls. A real authored 4 GiB GPT/APFS
COW fixture passed handoff/restoration using the production media scanner:
source full hash and UID/GID/mode/mtime/ctime were unchanged, the copy's full
hash matched and its mode returned to 0600. This host control uses the test
process UID, not kernel-attested app authority; it qualifies no iPad behavior.
No exchange, payload activation, snapshot invalidation, restart rollback,
health commit or automatic installation is enabled by this API.

### RAM snapshot quarantine before publication

`HGGuestSnapshotInvalidation` handles the fixed `resume.hsnap` and
`resume.hsnap.part` names beside a machine's `disk.img`. After durable publication
intent, retained write authority and an original-active image pair, it inventories
ordinary caller-owned snapshots, rejects links/ACLs/flags/busy files, and persists
a root-private 256-byte receipt bound to the exact publication record's SHA-256.
It then moves the recorded snapshot inodes into fixed private names using
exclusive rename. No snapshot/image bytes are modified or deleted. The original
snapshot file modes/ownership are preserved inside the private directory.

A freshly authorized original-active transaction can complete an interrupted
quarantine from that receipt. It re-syncs/read-backs the receipt before any move,
matches the fresh source authority to the original intent metadata (not a full
content hash), preflights all public/private inode locations, refuses replacements/duplicates,
moves only remaining known inodes, synchronizes both directories and verifies
all public snapshot names absent. An already-complete retry is idempotent and
still performs durability barriers. Read-only absence verification also works
across the two known image-pair positions; it grants no publication/boot rights.
Generic workspace cleanup retains these records, images and quarantined RAM.

Twenty-two ASan/UBSan intent/metadata/snapshot groups now pass. Snapshot controls
cover both names, absent inputs, partial moves and retry, receipt sync failure
including retry, replaced files, symlinks/hardlinks/busy snapshots, recreation of
a public name, cross-publication receipt rejection and swapped-image refusal for
completion. A real authored 4 GiB GPT/APFS COW host control with the production
media scanner preserved the source full hash/metadata and snapshot bytes/inodes,
and verified/completed the quarantine in separate processes. These are host
controls, not iPad qualification. No app/helper operation invokes quarantine yet:
production atomic exchange, restart supervisor, activation and health commit
remain incomplete. The iOS System/Data mount panic guard remains unchanged.

### Atomic rollback of an uncommitted image pair

`HGGuestPublicationRollback` restores the original-active pair with `RENAME_SWAP`
while retaining the failed copy and all its changes. It requires a freshly
reattested live peer, caller-opened write authority for the current active inode,
an independently/exclusively leased private image, the durable publication record,
matching original ownership/mode/mtime and complete snapshot quarantine. Fresh
media discovery must be empty for both images; peer, leases, namespace and snapshot
state are checked again after discovery. Root never opens the active image for
writing or accepts a source path/UID assertion as mutation authority.

Both directories are synchronized, the resulting inode pair is observed, and
retained file metadata/namespace/snapshots/peer are rechecked. A sync failure after
successful exchange reports original-active with durability unconfirmed. A fresh
process can then validate/sync the already-original-active pair without swapping
again. If a kernel or observation failure makes the pair unknown, no further
exchange or deletion is attempted. Callers must reopen leases after an attempted
exchange because rename can change inode ctime. This API grants no boot or commit
permission and exposes no forward publication or root-helper command.

Twenty-seven native sanitizer intent/metadata/snapshot/rollback groups pass. Native
rollback controls retain altered failed-copy bytes, exercise a fresh-process
idempotent retry, and refuse wrong/changed peer, busy media, recreated RAM state,
changed private metadata, late peer/namespace changes and injected rename/sync
failures. The rollback tests
stub peer attestation explicitly; they do not qualify kernel/root caller identity.
A real authored 4 GiB APFS COW control with the production media scanner restored
the original inode/full hash/owner/mode/mtime, retained the altered copy's full
hash and quarantined RAM, and retried from another process without another swap.
That host control also stubs peer identity; physical iPad rollback is unqualified.
Production forward exchange, app restart routing, activation/health commit and
fresh-guest acceptance remain incomplete. No live guest or checkpoint is changed
by these authored-image controls.

### Fixed-path guest payload delivery

`HGGuestPayloadDelivery` verifies the build-bound archive before creating any
paths, then stages its versioned closed inventory beneath the fixed
`Library/Application Support/Henge/Compatibility` path. Each component is opened
relative to a retained descriptor, matched by inode/device, and required to be
caller-owned, ordinarily permissioned, globally readable/searchable and free of
extended ACLs/flags. Symlinks and cross-device boundaries are refused. Newly
created directories become 0755 and are synchronized with their parents; existing
metadata and conflicting versions are preserved. The complete namespace is
revalidated after staging and final durability barriers. Staging/reuse now also
refuses ACLs/flags on its parent, version directory and payload members, and
requires members to remain on the expected filesystem.

The caller MUST already own/qualify a writable private-copy Data-volume root,
exclusive image lease, compatible System identity and detach transaction. This
lower layer establishes no mount/image authority and must never receive the
original/active guest root. Delivery does not select a current version, activate
injection, alter application bundles or authorize image publication. Its report
explicitly records no activation and no mount authority established by delivery.
No production root-helper command invokes it yet.

Twenty-five native payload/parser/staging/delivery groups pass, including every
path-component symlink, invalid archive before tree creation, unsafe permissions,
ACLs, preserved conflicts, unchanged unrelated data and exact version reuse.
The host controls run as the host user; they are not root-ownership qualification.
A real authored 4 GiB role-neutral COW Data volume received the independently
built complete payload at this fixed path. Roles were restored across new APFS
checkpoints, the payload reverified after a read-only remount, filesystem check
passed, all owned attachments disappeared, the copy was discarded and the
original source's full SHA-256 remained unchanged. This host hdiutil control
releases the copy lease around attachment; it does not qualify retained-lease
mounting on iPad. The iOS System/Data panic guard remains in place.
