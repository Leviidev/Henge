# Large wallpaper surfaces

The HEIC wallpaper logs contain 6016 x 6016 surfaces: a 54 MiB `420f`
surface followed by a 144 MiB BGRA allocation. These are consistent with
image decoding and conversion, although the logs do not identify the image
file or connect individual render commands to its cache file.

PVG surface lists hold 4096 entries per 16 KiB page. Up to 64 MiB they are
flat; larger allocations use a directory of leaf lists. The former flat
reader treated directory entries and adjacent memory as pixel page addresses.
GPU writes could therefore miss the actual image pages and overwrite unrelated
guest memory, including code. An instruction encoding check cannot prevent
that earlier overwrite.

The page walker now reads both levels, checks directory flags, bounds each
read to its table, and preserves missing pages. Large allocations log
`two-level page list, N/N pages mapped`; the reported 144 MiB allocation has
9216 pages, assuming no extra first-page offset. A failed host remap is logged
and the surface is rejected instead of drawing through a partial mapping.

Unmap acknowledgements now wait for preceding GPU work. Later mapper batches
cannot overtake that fence, duplicate doorbells do not resubmit unmaps, and
snapshot/teardown drain the callbacks before freeing the device.

Based on the first two fixes in upstream [PR #207](https://github.com/Leviidev/Henge/pull/207)
(commits `9bedbd9cdbd4` and `51e102dc76c0`); the page-table fix also appears in
[PR #187](https://github.com/Leviidev/Henge/pull/187).

## Verification

- `make test-pvg-surface`: portable page-table fixtures, including the 64 MiB
  boundary, 144 MiB allocation, scattered leaves, absent/invalid entries and
  truncated physical memory.
- `make test-pvg`: additionally exercises actual mapper MMIO with controlled
  completions, and real Metal queue completion during snapshot and teardown.
- The `PVG regression tests` GitHub Actions workflow runs these checks and
  iOS/macOS compile checks on pushes and pull requests touching this code.

The reporter confirmed that the original wallpaper problem was resolved with
these PVG changes in build `a2111ec`, on an iPad Pro 12.9-inch (6th generation,
16 GB RAM) running a macOS Sequoia 15.6.1 guest. That build included earlier
unrelated fixes; this branch ports only the PVG fix and its tests onto upstream
`main`. The earlier build also passed the Metal lifecycle and engine suites:
[build and test run](https://github.com/clyecao/Henge/actions/runs/44094900084).

On the iPad, fully shut down the guest and start it with the new build. Set a
fresh copy of the same HEIC as wallpaper, then select it again after switching
away; compare the rendered result and newly generated cache. Preserve logs if
it remains black. The separate multi-plane writeback gap and unsupported
type-12 texture objects are not addressed by this change, and this patch is
not yet proof that every HEIC wallpaper failure is resolved.
