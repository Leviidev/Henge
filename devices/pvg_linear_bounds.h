#ifndef HENGE_PVG_LINEAR_BOUNDS_H
#define HENGE_PVG_LINEAR_BOUNDS_H
#include <stdint.h>
/* PR137: the final row needs visible pixels, not trailing row padding. Use
   subtraction and division so malformed guest dimensions cannot wrap a sum. */
static inline int hv_pvg_linear_bounds(uint64_t width,uint64_t height,uint64_t bpp,
                                     uint64_t offset,uint64_t row,uint64_t length,uint64_t align) {
    return width && height && bpp && width<=UINT64_MAX/bpp && offset<=length &&
        width*bpp<=length-offset && row>=width*bpp &&
        (!align || (!(row%align) && !(offset%align))) &&
        height-1<=(length-offset-width*bpp)/row;
}
#endif
