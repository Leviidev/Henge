# Sonoma distribution acceptance

The release goal is an app built from this PR that supplies the entire existing
compatibility series on a matching iPad, including a fresh Sonoma guest, without
SSH, a compiler Mac, copied caches, guest shell commands, injected launch commands,
or a separately installed compatibility kit. Normal macOS installation and account
creation remain part of using Henge. Build-machine dependencies belong in CI.

## Current integration

`pr/sonoma-autosetup` contains the committed Sonoma series and renderer follow-ups,
reconciled with upstream `9aa4b6dbe10f23fb937941050b6934f695d20f3d`.
The source includes JIT readiness, trackpad pointer/scroll separation, auxiliary
DISCARD handling, mapped and planar surfaces, copyback, render store actions,
task epochs, ordered shader replay, on-device AIR conversion, lifecycle gates,
counter origin, settings icon fixes and bounded AGX diagnostics. Diagnostic tools,
authored tests, OpenGL discovery and VLC export source patches are retained.

| Requirement | Current evidence or remaining work |
| --- | --- |
| Ordinary graphics fixes enabled in the installed app | Production lineage qualified on iPadOS 17.0 / Sonoma 14.6.1. The newly reconciled binary still needs a device gate. |
| Cold executable shaders entirely on the iPad | In-process provider is linked by default; package creation refuses a missing or stale provider. The clean pinned-source build, authored native controls and full iOS package passed. Newly reconciled on-device cold rendering remains a separate gate. No imported cache may be used as proof of cold success. |
| All prior OpenGL discovery work available automatically | Incomplete: current implementation requires a process-scoped guest launcher. Implement automatic discovery for a fresh guest, preserving ordinary application signing policies. |
| All prior dynamic-library work entirely on the iPad | Partially ported: the embedded stateless compute linker passed three direct iPad GPU controls (768 exact outputs), without a runtime Mac compiler. Latest validation guards passed native controls. The clean combined provider build, archive-linked controls and full app package passed. Private guest transport and recipe discovery are implemented and passed native HTTP/API/GPU/cache controls. Automatic guest delivery/activation and iPad guest execution remain incomplete. |
| Automatic guest component provisioning | Scratch APFS attachment/write/remount passed on the iPad, with verified media ancestry, an exclusive inode lease and full cleanup. VM disk ownership locking now prevents concurrent writers. Packaging builds and embeds a versioned, manifest-bound guest adapter/discovery archive from source. The TrollStore package includes a read-only root helper and a bounded app-launch persona probe; app-context privileges are not yet qualified. Actual Sonoma Data-volume selection and atomic payload delivery/activation remain unimplemented. Developer Python/SSH controls are not release setup. |
| Existing VLC decoding/export work carried forward | Source recipes and patches are included. The builder can automatically acquire and verify the pinned official reference app instead of requiring an operator-supplied app. Automatic guest delivery of the compatibility components and the patched VLC build is not yet integrated. Preserve stock apps and user data. |
| Manual icon/cache repairs unnecessary | New clean guest must show the icons without cache repair. Existing blank guest caches need a versioned, backup-preserving migration if normal invalidation does not suffice. |
| Reproducible release build | Pinned clean-source provider and complete local app build passed; package recipe and license inspected. CI includes the build and controls, but fork workflow dispatch is not yet registered. See [exact validation scope](distribution-validation.md). |
| Compatibility with new upstream snapshots | Snapshot state carries mapper admission and task epochs. Check inactive CPU wake, pending replay/shader jobs, GPU copyback and background save before claiming the combination qualified. |
| Upstream PR | Publish the complete source changes and an accurate validation report. A draft is not completion of this plan. |

## Final gates

1. Inventory every local change since the original checkout, including guest-only
   changes. Trace each retained fix to a tracked source path and an automatic
   activation path. Exclude credentials, guest disks, captured Apple libraries,
   local addresses, generated caches and diagnostic session files.
2. Build and package from a clean source snapshot with only declared public build
   inputs. Verify required symbols, resources, recipes, licenses and entitlements
   in the resulting app. Test the actual CI build path, not an archive copied from
   an earlier experiment.
3. Use a separate fresh Sonoma guest on the matching iPad setup. Preserve the
   existing working guest. Leave Mac compiler services stopped and supply no
   shader caches, tokens, SSH configuration or manual guest compatibility steps.
4. Exercise settings icons, image effects, HEIC, static and Sonoma Horizon
   wallpapers, newly authored cold Metal/WebGL shaders, the supported dynamic
   closure controls, ordinary OpenGL applications and the existing VLC
   H.264/HEVC playback/export controls. Verify pixels/readback as well as absence
   of shader errors. Record any unsupported cases rather than treating a fallback
   texture as success.
5. Check Magic Keyboard pointer and scroll independently, idle display wake,
   app switching, iPad lock/wake, clean shutdown, supported snapshot/resume and
   in-place upgrade data preservation on the final binary.
6. Publish the PR with exact source/build identities, automatic runtime behavior,
   validation results and remaining limitations. Historical AGX crashes,
   intermittent YouTube corruption and accessory-manager kernel panics remain
   separate unresolved investigations; packaging is not proof they are fixed.

Compiler inventory counts do not establish GPU execution coverage. A warm cache
does not establish cold on-device compilation. A build or native unit-test pass
does not qualify a new device binary. This plan stays open until each automatic
activation and fresh-install gate has authoritative evidence.
