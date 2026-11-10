#ifndef HV_PVG_TEXTURE_RECORD_H
#define HV_PVG_TEXTURE_RECORD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t mapping;
    uint32_t tag, descriptor_size, reference, plane;
    const uint8_t *descriptor;
} HvMappedTextureRecord;

static inline uint32_t hv_pvg_texture_u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* The descriptor size includes its {tag,size,ref} header, but excludes
   the eight-byte surface mapping ID. The last word selects its plane.
   Captured Sonoma records use tag 0x2f/size 48; the swizzle-bearing v2
   record uses tag 0x39/size 56. Reject truncated/unknown forms explicitly. */
static inline bool hv_pvg_decode_mapped_texture(const uint8_t *bytes, size_t length,
                                               HvMappedTextureRecord *out) {
    if (!bytes || !out || length < 20) return false;
    uint32_t tag = hv_pvg_texture_u32(bytes + 8);
    uint32_t size = hv_pvg_texture_u32(bytes + 12);
    uint32_t expected = tag == 0x2f ? 48 : tag == 0x39 ? 56 : 0;
    if (!expected || size != expected || length < (size_t)size + 8) return false;
    *out = (HvMappedTextureRecord){
        .mapping = (uint64_t)hv_pvg_texture_u32(bytes) |
                   (uint64_t)hv_pvg_texture_u32(bytes + 4) << 32,
        .tag = tag, .descriptor_size = size,
        .reference = hv_pvg_texture_u32(bytes + 16),
        .plane = hv_pvg_texture_u32(bytes + 8 + size - 4),
        .descriptor = bytes + 20,
    };
    return true;
}

#endif
