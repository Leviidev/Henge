# Memory and JIT integration

Built on current upstream e98920c. Adds exact-tag multiwindow kernel read caching, checked helper read-span reuse, grouped address reuse, complete cache-line publication, inline hot system registers, and event waits for full quiescence. Defaults retain permissions, PAN/EL, ASID invalidation, MMIO and precise slow-path fallbacks. Executable code remains session-only.

The segmented JIT ring and hot-system-register work derive in part from oliverames/Henge (upstream PR #186); this is an integration and additional correctness/performance work, not an independent claim of authorship. Related prior experiments: bradenbeast PRs #78/#80/#81 and selected custom-fork engine work. The upstream review should retain that original attribution; this branch combines that groundwork with the additional checked-reuse and selective branch-cache changes described below.

Native checks: `make test-memory-jit`, then the existing `make test` on arm64 macOS. This extracted branch has NOT yet been cloud compiled. The previously shipped aggregate passed these tests; that is not validation of this rebase. No hardware thermal/FPS improvement is claimed.

No app branding, version changes, iOS17 Metal removal, IPA workflow or translation-layer deletions are included. New upstream Mac Apps sources remain intact.


The extended branch includes interleaved-base checked reuse, indexed IJC eviction,
non-FIFO diagnostic ownership and opt-in recent-use/site-hint/paired-entry trials.
Defaults retain ordinary FIFO and leave the slower/unproven scheduling trials off.
The segmented ring/sysreg groundwork overlaps Oliver Ames's PR186; shared-region
work overlaps PR157. Preserve that attribution when extracting this integrated
follow-up; this contribution adds checked memory/PAN/invalidation coverage and
cache-preservation extensions rather than claiming the original ring design.
Native custom-integration regression/ASan/UBSan/TSan and full app build passed
43719589751; updated standalone upstream-engine validation follows separately.
Physical M4/Duo FPS and energy are not measured by the cloud M1 runner.
