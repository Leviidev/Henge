#ifndef HENGE_PVG_LINK_H
#define HENGE_PVG_LINK_H
#include <stdint.h>
/* Opt-in second port, configured only before boot. Zero disables it. */
int hv_pvg_lite_set_link_mode(uint32_t width, uint32_t height, uint32_t width_mm,
                             uint32_t height_mm, uint32_t hz);
#if defined(__OBJC__) || defined(__BLOCKS__)
/* Texture and queue are borrowed during the synchronous callback. The callback
   must issue its GPU snapshot on that queue before returning. No CPU readback. */
typedef void (^HvPvgLinkFrameHandler)(void *texture, void *queue, uint32_t half_mode,
    void *cursor_texture, float cursor_x, float cursor_y, float cursor_w, float cursor_h);
void hv_pvg_link_set_frame_handler(HvPvgLinkFrameHandler handler);
/* Optional mirror of port zero; never changes guest topology or local output. */
void hv_pvg_link_set_primary_frame_handler(HvPvgLinkFrameHandler handler);
#endif
#endif
