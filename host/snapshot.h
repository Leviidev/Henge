#ifndef HENGEVM_SNAPSHOT_H
#define HENGEVM_SNAPSHOT_H

#include <stddef.h>
#include <stdint.h>

/* Instant resume: the whole machine (CPUs, RAM, devices, the screen) in one file, and back.

   Saving needs a machine paused with hv_vm_pause (every CPU out of guest code, devices idle, the GPU's own memory
   copied back into the guest's). Restoring goes into a machine just made by hv_vm_create with the same settings, before
   hv_vm_start. ident is the caller's own description of what the file is valid for (the app's build, the Mac, its disk
   as it was when saved); a file made under another ident, or by another build of the engine, is refused.

   The disk is not in the file: it has to be exactly as it was when the file was written, so a file must be resumed at
   most once, and never after the Mac has run on without it. */
/* Two packing sets, stage + output per4MB chunk: about16MB per worker.
   Preserve64MB headroom; allocation failure can reduce the batch further. */
static inline unsigned hv_snapshot_workers(unsigned active, uint64_t headroom) {
    unsigned count = active ? (active < 8 ? active : 8) : 1;
    uint64_t room = headroom > (64ull << 20) ? (headroom - (64ull << 20)) / (16ull << 20) : 1;
    if (!room) room = 1;
    return room < count ? (unsigned)room : count;
}

int hv_snapshot_save(const char *path, const char *ident, char *err, size_t errlen);
/* Callbacks may run on packing workers. Cancellation must be thread safe and
   stay set for this operation; progress runs on the writer. No file format or
   guest state changes. All workers finish before this function returns. */
typedef struct HvSnapshotControl {
    int (*cancelled)(void *context);
    void (*progress)(uint64_t scanned, uint64_t total, void *context);
    void *context;
    unsigned workers; /* 0: existing batch size; otherwise 1..8 */
    int background;   /* bounded automatic save; never a vCPU QoS change */
} HvSnapshotControl;
int hv_snapshot_save_controlled(const char *path, const char *ident, const HvSnapshotControl *control,
                                char *err, size_t errlen);
int hv_snapshot_restore(const char *path, const char *ident, char *err, size_t errlen);
/* 0 if path holds a complete snapshot made with ident by this build; its size in bytes and when it was made. */
int hv_snapshot_check(const char *path, const char *ident, uint64_t *bytes, int64_t *saved_at);
typedef struct HvSnapshotInfo { uint64_t bytes, ram_mb; int64_t saved_at; uint32_t cpus; } HvSnapshotInfo;
/* Read only the validated header/trailer, never allocate guest RAM. The caller
   must validate its own identity/build before attempting a restore. */
int hv_snapshot_inspect(const char *path, char *ident, size_t ident_capacity, HvSnapshotInfo *info);

#endif
