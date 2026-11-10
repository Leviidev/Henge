# Bounded ordinary texture decoding

The renderer now shares a length-checked ordinary texture-record decoder with
the original lineage's texture-first legacy-table recognizer. Layout and mip
ranges, declared descriptor bounds and page-rounding overflow are checked before
field access or layout allocation/copy; allocation failure is handled explicitly.
Existing v1/v2 descriptor dispatch and rendering semantics are retained.

The original lineage additionally accepts a first object that is a known,
bounded single-sample/single-slice uncompressed 2D R8/RG8/RGBA8/BGRA8 texture.
It validates all mip spans and every backing page, with a 4MiB backing policy.
Unknown formats, array/cube/3D/compressed variants, descriptor tags and larger
backings remain unsupported as the first object. This policy is not a claim
about all valid Metal textures, and it does not forbid those textures after a
separately established table. It does not snapshot or pin guest page-table memory.

Current upstream already selects its old-driver table at offset0x4000 without
first-object inference. The reconciled branch preserves that behavior. It uses
the shared bounds-checked renderer decoder, but does not claim to apply the
original lineage's stricter first-object/backing-page recognition policy.

Run `make test-pvg-ordinary-texture` or `python3 tests/test_pvg_ordinary_texture.py`.
There are 977 deterministic CPU checks with AddressSanitizer and UndefinedBehavior-
Sanitizer, covering authored normal records, complete mip chains, field extraction,
bounded truncation and unsupported-layout rejection. No GPU calls execute.
Existing mapped-texture decoder tests remain separate. The original production
lineage subsequently passed all four actual texture-first early/late clear
readbacks with zero mismatches. This is separate from the parser checks and
does not qualify the reconciled latest-upstream binary on-device.

This change is independent of task-cache identity, the paired GL vertex/viewport
conversion, and the unresolved historical AGX driver abort.
