#ifndef HV_DISPLAY_SNAPSHOT_H
#define HV_DISPLAY_SNAPSHOT_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#define HV_DISPLAY_SNAPSHOT_VERSION 2u
#define HV_DISPLAY_SNAPSHOT_PORTS 2u
typedef struct HvDisplaySnapshotPort {
    uint64_t mapping;
    uint32_t width, height, stride, shown;
    int32_t hot_x, hot_y;
} HvDisplaySnapshotPort;
typedef struct HvDisplaySnapshot {
    uint32_t version, ports;
    HvDisplaySnapshotPort port[HV_DISPLAY_SNAPSHOT_PORTS];
} HvDisplaySnapshot;
/* Validate before allocating or touching any live renderer state. */
static inline int hv_display_snapshot_parse(const void *in, size_t len,
                                            HvDisplaySnapshot *out, size_t bytes[2]) {
    if (!in || len < sizeof *out) return -1;
    memcpy(out, in, sizeof *out);
    if (out->version != HV_DISPLAY_SNAPSHOT_VERSION || out->ports != 2) return -1;
    size_t total = sizeof *out;
    for (unsigned p = 0; p < 2; p++) {
        const HvDisplaySnapshotPort *d = &out->port[p];
        if (d->shown > 1 || d->width > 512 || d->height > 512 || d->stride > 8192) return -1;
        if ((!d->width || !d->height) && (d->width || d->height || d->stride)) return -1;
        if (d->stride < d->width * 4) return -1;
        bytes[p] = (size_t)d->stride * d->height;
        if (bytes[p] > len - total) return -1;
        total += bytes[p];
    }
    return total == len ? 0 : -1;
}
#endif
