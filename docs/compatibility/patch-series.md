# Source series and review boundaries

Two isolated series are maintained. The original production lineage starts at
`f9c12c93620af4c4c5f5f65f9793b72f883be682`. The reconciled upstream series was
checked against `Leviidev/Henge` main at
`0a1e6a5b8f53a6faf2b274a0a75fa87e47f17e50`. Record the exported manifest's exact
base, HEAD, tree and patch hashes; do not assume main remains at that commit.

The logical changes are separate commits:

1. Held/tested JIT readiness and physical pointer/touch routing.
2. Auxiliary block DISCARD, bounded panic candidate scanning and real worker tests.
3. Sonoma record/page decoding, recipe-qualified shader conversion, mapped surface
   lifetime/layout and GPU copyback, with authored controls.
4. Portable diagnostic sources and fixture generation, configurable dependencies,
   source/build manifests and guarded TrollStore update/health/rollback tools.
5. Replay task create/destroy identity and epoch invalidation, with an actual
   four-process ABBA reuse gate and portable Foundation-only controls.
6. Late render attachment store actions, independently checked by parser/native
   Metal controls and actual guest clear/GLSL/readback evidence.
7. Opt-in AGX selected-byte/pipeline provenance. This is diagnostics, not a driver
   crash repair or a change to Metal-object retention.
8. Optional VLC source patches and independent source rebuild/export controls.
9. Optional process-scoped OpenGL discovery and native app launcher; system renderer
   registration remains unchanged and clip-space limitations remain explicit.
10. Optional stateless compute dynamic-library adapter and authenticated compiler.

Upstream reconciliation retains its trackpad finger-frame path, legacy record
fallback, descriptor-reuse handling, planar aliases and ordered GPU teardown.
Alias wrappers now refer to a canonical surface so upload shadows, pending GPU
copyback and per-plane state are shared consistently. The newer generalized
metadata relabel and native diagnostic controls are retained. These combinations
need their own device review; original-lineage device results do not qualify a
new upstream binary merely because compilation and native controls pass.

Create a new immutable export from a clean, committed checkout:

```sh
python3 tools/compat/export_series.py --base RECORDED_BASE --output /path/new-series
```

It rejects binary changes, writes ordered patches and SHA256 manifests, applies
them to a fresh checkout and verifies the resulting Git tree matches exactly.
That is a source-application check. Follow [the reproduction guide](reproduce-ios17.md)
for actual build, package and runtime acceptance.

A reviewer can apply an exported series in their own clean clone:

```sh
git switch -c review/henge-compat RECORDED_BASE
git am /path/new-series/patches/*.patch
```

Do not include the local validation clone, generated apps, caches, private device
receipts or captured Apple shader files in a PR. Source distributions contain the
patches, authored controls and dependency/source provenance only. Keep old series
immutable when later fixes arrive; publish a new manifest and preserve which
runtime receipts belong to each source lineage. No push or PR is performed by the
export tool.
