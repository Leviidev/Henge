#ifndef HENGE_CURSOR_DENSITY_H
#define HENGE_CURSOR_DENSITY_H
#include <stdint.h>
/* Explicit choices win. Auto uses the guest panel's physical density, not a
   second device-model policy or preferences access on every presented frame. */
static inline unsigned hv_cursor_density_scale(unsigned selected,uint32_t width,uint32_t mm,unsigned fallback) {
    if(selected>=1 && selected<=3)return selected;
    if(mm && (uint64_t)width*254 >= (uint64_t)mm*1500)return 1;
    return fallback;
}
#endif
