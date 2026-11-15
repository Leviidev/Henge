#ifndef HENGE_CURSOR_DAMAGE_H
#define HENGE_CURSOR_DAMAGE_H
#include <stdint.h>
typedef struct HvCursorDamageKey {
    uint64_t layer, glyph;
    uint32_t position, width, height, settings;
    int hot_x, hot_y, visible;
} HvCursorDamageKey;
typedef struct HvCursorDamage { HvCursorDamageKey prior; int valid; uint64_t suppressed; } HvCursorDamage;
static inline int hv_cursor_damage_changed(HvCursorDamage *state, HvCursorDamageKey next) {
    if (!next.visible) next = (HvCursorDamageKey){.layer=next.layer};
    HvCursorDamageKey *p = &state->prior;
    if (state->valid && p->layer == next.layer && p->glyph == next.glyph &&
        p->position == next.position && p->width == next.width && p->height == next.height &&
        p->settings == next.settings && p->hot_x == next.hot_x && p->hot_y == next.hot_y && p->visible == next.visible) {
        state->suppressed++; return 0;
    }
    state->valid = 1; state->prior = next; return 1;
}
#endif
