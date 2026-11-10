# Opt-in Metal compilation provenance

This is diagnostic evidence capture, not a repair for the historical AGX vertex-program unfair-lock crash. That failing descriptor and its selected library bytes were not captured; its cause remains unproven. No Metal object ownership, global compiler locking, function substitution, or error-recovery policy changes here.

Create an empty `agx-journal-enable` file in Henge's Documents directory before a fresh ordinary app session. Use the operator-selected app data container and existing authenticated device tooling; no device address or container UUID is embedded here. Remove the marker and restart Henge to disable capture. This marker is independent of `shader-audit-capture` and does not enable its legacy archive.

`Documents/agx-journal/` contains per-process session directories, a latest-session pointer, selected-library bytes after successful loads, serialized descriptors before deserialization, and phase events before/after ordinary pipeline compilation. Source and actually selected byte hashes are distinct. A retry snapshots the current descriptor's replacement functions; original guest references remain separately labelled deserialization bindings. Previously cached functions without observed selection are explicitly unknown.

Each session retains 128 events, at most 256 KiB each; blobs are deduplicated, at most 32 MiB each, 64 MiB total and 4096 entries. Old sessions are not automatically deleted. Archive failures are recorded without forcing Metal failure; atomic writes do not promise power-loss durability. Debug-only getters and I/O can perturb timing. Captures may contain proprietary shader bytes and process-local addresses: keep them private and out of source distributions.

Run `make test-agx-journal` on an Apple Silicon Mac with the Metal compiler installed. This builds two authored libraries and performs two successful public-API pipeline compilations; it checks disabled behavior, exact selected bytes, and independently labelled snapshots. It never dispatches GPU work or induces a fault. Manually labelled first/retry events in this helper are not proof of automatic production retry behavior. Normal guest-workload integration remains a separate qualification gate.

The production lineage also passed one ordinary successful guest render-pipeline
recording on the tested iPad/Sonoma route: ordered `before_deserialize`,
`first_entered_driver`, `first_created` events; actual broker-selected vertex and
fragment archives matched their recorded hashes and installed executable UUID.
The marker was removed afterward. No failure or automatic retry was induced.
This qualifies that bounded production route, not the separately reconciled
latest-upstream binary or the historical crash.
