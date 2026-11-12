#ifndef HENGE_PVG_SURFACE_COPYBACK_H
#define HENGE_PVG_SURFACE_COPYBACK_H
#include <stdbool.h>
#include <stdint.h>

/* One plane in the guest layout, independent of the host IOSurface padding. */
typedef struct {
    uint64_t guest_offset, shadow_offset, row, image, width, height, active_row;
} HvPvgSurfaceCopyback;

static inline bool hv_pvg_surface_copyback_plan(uint64_t first, uint64_t alloc,
        uint64_t mapped_length, uint64_t offset, uint64_t row, uint64_t width,
        uint64_t height, uint64_t bytes_per_element, HvPvgSurfaceCopyback *out) {
    if (!out || first >= 0x4000 || first > mapped_length || !alloc ||
        alloc > mapped_length - first || !width || width > 8192 ||
        !height || height > 8192 || !bytes_per_element || bytes_per_element > 16 ||
        !row || row > (1u << 20) || row < width * bytes_per_element ||
        row % bytes_per_element || offset > alloc || height > (alloc - offset) / row ||
        offset % bytes_per_element || (first + offset) % bytes_per_element) return false;
    *out = (HvPvgSurfaceCopyback){first + offset, offset, row, row * height,
        width, height, width * bytes_per_element};
    return true;
}

#ifdef __OBJC__
#import <Metal/Metal.h>
/* The caller encodes this after the writes, in the same command buffer. GPU
 * commands update both guest memory and the CPU-change baseline before the
 * guest receives completion. A missing optional shadow only loses the skip
 * optimization; guest copyback still happens. All buffers are retained by CB. */
static inline bool hv_pvg_encode_surface_copyback(id<MTLBlitCommandEncoder> blit,
        id<MTLTexture> plane, id<MTLBuffer> guest, id<MTLBuffer> shadow,
        const HvPvgSurfaceCopyback *p) {
    if (!blit || !plane || !guest || !p || plane.width < p->width ||
        plane.height < p->height || plane.sampleCount != 1 ||
        p->guest_offset > guest.length || p->image > guest.length - p->guest_offset ||
        (shadow && (p->shadow_offset > shadow.length || p->image > shadow.length - p->shadow_offset))) return false;
    MTLSize size = MTLSizeMake(p->width, p->height, 1);
    [blit copyFromTexture:plane sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:size toBuffer:guest destinationOffset:p->guest_offset
      destinationBytesPerRow:p->row destinationBytesPerImage:p->image];
    if (shadow)
        [blit copyFromTexture:plane sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:size toBuffer:shadow destinationOffset:p->shadow_offset
          destinationBytesPerRow:p->row destinationBytesPerImage:p->image];
    return true;
}
#endif
#endif
