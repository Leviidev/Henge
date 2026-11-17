#include "pvg_surface.h"

#include <stdlib.h>
#include <string.h>

/* A 16 KB list holds 4096 page entries (64 MiB of pixels). Larger surfaces use
   a directory of list pages. Reading that directory as a flat list maps the
   tables themselves and unrelated memory as pixels, allowing GPU writes to
   overwrite guest code. See upstream Henge #207 / #187. */
uint32_t *hv_pvg_surface_pages(void *opaque, HvPvgSurfaceRead read, uint32_t list, uint64_t count) {
    const uint64_t per = 4096;
    if (!read || !(list & 1) || !count || count > per * per) return NULL;
    uint32_t *out = calloc((size_t)count, sizeof *out);
    if (!out) return NULL;
    uint64_t at = (uint64_t)(list & ~1u) << 12;
    if (count <= per) {
        const void *p = read(opaque, at, count * sizeof *out);
        if (!p) { free(out); return NULL; }
        memcpy(out, p, (size_t)count * sizeof *out);
        return out;
    }
    uint64_t lists = (count + per - 1) / per;
    const uint8_t *dir = read(opaque, at, lists * sizeof *out);
    if (!dir) { free(out); return NULL; }
    for (uint64_t k = 0; k < lists; k++) {
        uint32_t entry;
        memcpy(&entry, dir + k * sizeof entry, sizeof entry);
        if ((entry & 3) != 3) continue; /* both present and list-page flags */
        uint64_t n = count - k * per;
        if (n > per) n = per;
        const void *p = read(opaque, (uint64_t)(entry & ~3u) << 12, n * sizeof *out);
        if (p) memcpy(out + k * per, p, (size_t)n * sizeof *out);
    }
    return out;
}
