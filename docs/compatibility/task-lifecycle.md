# Replay task lifetime and cache identity

The create command encodes `task_id << 1`, but destroy carries the direct task
ID. Shifting both deleted an unrelated task and retained the destroyed task's
cached shaders and pipelines. A later process could reuse the same task ID,
root/table addresses and 12-byte object entry while supplying different shader
bytes. The old entry comparison then returned the prior pipeline without a new
deserialization or compile.

Destroy now removes the direct ID. Ordered worker creates invalidate the encoded
ID's object cache. Both device-side create paths reset table/placement metadata
and publish a new creation epoch even when the root page is reused. The worker
observes that epoch before comparing object-table entries; this also covers the
root-ring create path that does not pass through the Metal submit worker.

Only the serial Metal worker mutates host object-cache dictionaries. Shared
mapper surfaces and shader recipe caches are not cleared. Device metadata is
never reset by a delayed worker destroy, which could otherwise erase a newer
published root. Independently retained command-buffer resources keep their
existing ownership semantics.

Run `make test-pvg-task-lifecycle`. The portable test extracts the actual four
production helper bodies, verifies their callsites and runs eleven Foundation
checks without GPU/device calls. It includes the former wrong-ID expression as
a negative control. It handles the original lineage's explicit legacy-table
flag and current upstream's computed legacy fallback separately.

The production lineage passed an actual iPad ABBA regression: four fresh
processes reused task21, all four selected their correct normal/compensated
vertex bytes and created new pipeline states. Diagnostic paired-depth controls
passed21/21 twice; uncompensated controls still failed seven expected cases.
This qualifies task-cache identity. The separately integrated protocol3
shader/viewport fix then passed the unmodified GL depth and image controls;
see [paired OpenGL qualification](profiled-opengl.md). Diagnostic compensated
shader fixtures are not the production implementation.

The transport still publishes roots/list metadata before queued Metal work.
Epoch invalidation is not a snapshot of all guest task memory and does not prove
arbitrarily overlapped old/new lifetimes are safe while old work reads guest
pages. The tested regression is sequential process reuse. This bug is also
separate from the unresolved historical AGX unfair-lock abort.
