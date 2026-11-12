# Golden Gate on 11-inch iPad Air M3 — baseline and profiling

This branch is experimental. It must not change virtual disk formats, NVRAM,
guest hardware identity, or existing macOS installation data.

## Safe baseline

- Guest memory: 4 GiB (do not allocate the iPad's full 8 GiB).
- Virtual CPUs: 4, then compare against 6 using the same workload.
- Screen: Performance; refresh: 60 Hz, with 30 Hz only if supported and tested.
- Faster disk writes: use the existing option; measure reliability.
- Superblocks: off for baseline, then compare on.
- Keep JIT enabled and do not assume larger JIT cache is always faster.

## Repeatable performance capture

1. Cold boot Golden Gate; record seconds to login and desktop usable.
2. Wait five minutes, then open Finder, System Settings, and a local file.
3. Record CPU utilization, memory pressure, thermal state, frame delivery,
   profiler samples and GPU trace (when available).
4. Repeat each configuration three times; compare median timings.
5. Record freezes, display artifacts, disk errors and process termination.
6. Compare against unmodified main on the same iPad and virtual disk snapshot.

Do not change the original virtual disk during benchmarking without a backup.
An unsigned IPA still needs signing and JIT authorization on the device.
