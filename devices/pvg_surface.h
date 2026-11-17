#ifndef HENGEVM_PVG_SURFACE_H
#define HENGEVM_PVG_SURFACE_H

#include <stdint.h>

/* Return guest physical bytes, or NULL when the entire range is not readable. */
typedef const void *(*HvPvgSurfaceRead)(void *opaque, uint64_t pa, uint64_t length);

/* One entry per 16 KB of surface memory. Caller frees the result; missing list
   pages leave zero entries. NULL means an absent root or an unsupported size. */
uint32_t *hv_pvg_surface_pages(void *opaque, HvPvgSurfaceRead read, uint32_t list, uint64_t count);

#endif
