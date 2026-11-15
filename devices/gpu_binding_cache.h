#ifndef HENGE_GPU_BINDING_CACHE_H
#define HENGE_GPU_BINDING_CACHE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* One last exact setter per independent encoder state family. A different
 * range/opcode replaces that family's proof: overlapping ranges, offset-only
 * changes and stride/LOD variants cannot leave an older proof live. Reset at
 * every encoder boundary. Resource identities are resolved host objects, never
 * reusable guest refs. Production command buffers retain their references. */
enum HvBindingFamily {
    HV_BIND_PIPELINE, HV_BIND_VERTEX_BUFFER, HV_BIND_FRAGMENT_BUFFER,
    HV_BIND_TILE_BUFFER, HV_BIND_VERTEX_TEXTURE, HV_BIND_FRAGMENT_TEXTURE,
    HV_BIND_TILE_TEXTURE, HV_BIND_VERTEX_SAMPLER, HV_BIND_FRAGMENT_SAMPLER,
    HV_BIND_DEPTH, HV_BIND_VIEWPORT, HV_BIND_SCISSOR, HV_BIND_CULL,
    HV_BIND_BIAS, HV_BIND_CLIP, HV_BIND_WINDING, HV_BIND_FILL,
    HV_BIND_STENCIL, HV_BIND_BLEND, HV_BIND_TESS_FACTOR, HV_BIND_TESS_SCALE,
    HV_BIND_FAMILY_COUNT
};
enum { HV_BIND_KEY_BYTES = 2048 };
typedef struct {
    uint16_t length[HV_BIND_FAMILY_COUNT];
    uint8_t valid[HV_BIND_FAMILY_COUNT];
    uint8_t bytes[HV_BIND_FAMILY_COUNT][HV_BIND_KEY_BYTES];
    uint64_t attempts, skipped;
    bool disabled;
} HvBindingCache;
static inline void hv_binding_reset(HvBindingCache *c) {
    memset(c->valid, 0, sizeof c->valid);
}
static inline bool hv_binding_update(HvBindingCache *c, unsigned family,
                                    const void *key, size_t length) {
    c->attempts++;
    if (c->disabled || family >= HV_BIND_FAMILY_COUNT) return true;
    if (!key || !length || length > HV_BIND_KEY_BYTES) {
        c->valid[family] = 0;
        return true;
    }
    if (c->valid[family] && c->length[family] == length &&
        !memcmp(c->bytes[family], key, length)) {
        c->skipped++;
        return false;
    }
    memcpy(c->bytes[family], key, length);
    c->length[family] = (uint16_t)length;
    c->valid[family] = 1;
    return true;
}
#endif
