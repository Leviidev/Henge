#ifndef HENGE_PVG_SURFACE_PAGES_H
#define HENGE_PVG_SURFACE_PAGES_H

#include <stdint.h>
#include <string.h>

typedef const void *(*HvSurfaceReadPhysical)(void *, uint64_t, uint64_t);

/* Sonoma IOSurface entries use 4 KiB address units over 16 KiB pages.
 * Captured guest tables: 01 is a data page; 11 points to another table.
 * A leaf holds 4096 data entries (64 MiB). Up to our 512 MiB surface limit,
 * at most one additional table level is needed. Reject unsupported/missing
 * entries instead of aliasing a page table as writable pixel storage.
 * Output entries retain their present bit; callers mask both low bits.
 */
static inline int hv_pvg_surface_pages(uint32_t list, uint64_t count,
                                      uint32_t *out, void *context,
                                      HvSurfaceReadPhysical read_physical) {
    if (!out || !read_physical || !count || count > 32768) return 0;
    memset(out, 0, count * sizeof *out);
    if ((list & 3u) != 1u) return 0;
    const uint32_t *root = read_physical(context, (uint64_t)(list & ~3u) << 12, 0x4000);
    if (!root) return 0;
    unsigned kind = root[0] & 3u;
    if (kind == 1u) {
        if (count > 4096) return 0;
        for (uint64_t i = 0; i < count; i++) {
            if ((root[i] & 3u) != 1u || !(root[i] & ~3u)) return 0;
            out[i] = root[i];
        }
        return 1;
    }
    if (kind != 3u) return 0;
    for (uint64_t first = 0; first < count; first += 4096) {
        uint32_t entry = root[first / 4096];
        if ((entry & 3u) != 3u || !(entry & ~3u)) return 0;
        const uint32_t *leaf = read_physical(context, (uint64_t)(entry & ~3u) << 12, 0x4000);
        if (!leaf) return 0;
        uint64_t n = count - first;
        if (n > 4096) n = 4096;
        for (uint64_t i = 0; i < n; i++) {
            if ((leaf[i] & 3u) != 1u || !(leaf[i] & ~3u)) return 0;
            out[first + i] = leaf[i];
        }
    }
    return 1;
}
#endif
