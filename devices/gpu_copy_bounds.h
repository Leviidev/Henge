#ifndef HV_GPU_COPY_BOUNDS_H
#define HV_GPU_COPY_BOUNDS_H
#include <stdint.h>
/* Checked arithmetic for one complete mip/array slice; no partial-copy claim. */
static inline int hv_gpu_copy_range(uint64_t base, uint64_t stride, uint64_t slice,
    uint64_t offset, uint64_t row, uint32_t height, uint32_t depth, uint32_t block_height,
    uint64_t length, uint64_t *from, uint64_t *image) {
    if (!row || !height || !depth || !block_height || base > length) return 0;
    if (slice && stride > (length - base) / slice) return 0;
    uint64_t start = base + stride * slice;
    if (offset > length - start) return 0;
    start += offset;
    uint64_t rows = ((uint64_t)height + block_height - 1) / block_height;
    if (rows > (length - start) / row) return 0;
    uint64_t plane = rows * row;
    if (depth > (length - start) / plane) return 0;
    *from = start; *image = plane;
    return 1;
}
#endif
