#ifndef HV_PVG_STORE_ACTION_H
#define HV_PVG_STORE_ACTION_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint64_t value;
    uint32_t index;
} HvStoreAction;

/* Sonoma's render encoder writes these fields in little endian, excluding
   the command envelope. Color actions use two u32s; color options use a
   u64 followed by a u32. Depth/stencil values are u64s. */
static inline bool hv_pvg_decode_store_action(uint32_t tag, const void *bytes,
                                              size_t length, HvStoreAction *out) {
    bool color = tag == 102 || tag == 103;
    bool options = tag == 103 || tag == 106 || tag == 121;
    if (!(color || tag == 105 || tag == 106 || tag == 120 || tag == 121)) return false;
    size_t needed = tag == 103 ? 12 : 8;
    if (!bytes || !out || length < needed) return false;
    const uint8_t *p = bytes;
    HvStoreAction action = {0};
    if (tag == 102) {
        uint32_t value;
        memcpy(&value, p, 4);
        action.value = value;
        memcpy(&action.index, p + 4, 4);
    } else {
        memcpy(&action.value, p, 8);
        if (color) memcpy(&action.index, p + 8, 4);
    }
    /* Unknown (4) is only valid on the initial descriptor, not a final setter. */
    if (color && action.index >= 8) return false;
    if (options ? (action.value & ~UINT64_C(1)) != 0
                : action.value > 5 || action.value == 4) return false;
    *out = action;
    return true;
}

#ifdef __OBJC__
/* Called only for the six known tags, before endEncoding. */
static inline bool hv_pvg_apply_store_action(id<MTLRenderCommandEncoder> encoder,
                                            uint32_t tag, const void *bytes, size_t length) {
    HvStoreAction action;
    if (!hv_pvg_decode_store_action(tag, bytes, length, &action)) return false;
    switch (tag) {
    case 102: [encoder setColorStoreAction:(MTLStoreAction)action.value atIndex:action.index]; break;
    case 103: [encoder setColorStoreActionOptions:(MTLStoreActionOptions)action.value atIndex:action.index]; break;
    case 105: [encoder setDepthStoreAction:(MTLStoreAction)action.value]; break;
    case 106: [encoder setDepthStoreActionOptions:(MTLStoreActionOptions)action.value]; break;
    case 120: [encoder setStencilStoreAction:(MTLStoreAction)action.value]; break;
    case 121: [encoder setStencilStoreActionOptions:(MTLStoreActionOptions)action.value]; break;
    }
    return true;
}
#endif
#endif
