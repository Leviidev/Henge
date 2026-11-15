#pragma once
#include <stdint.h>
typedef struct { uint32_t width,height; } HvDesktopOutput;
/* Primary mode, not a transient WindowServer surface, fixes the output canvas.
   Cursor coordinates remain in guest-mode pixels; normalized rects scale once. */
static inline HvDesktopOutput hv_desktop_output(uint32_t w,uint32_t h,uint32_t mode_w,uint32_t mode_h,int scale) {
    if(scale==2 && mode_w && mode_h && mode_w<=4096 && mode_h<=4096)
        return (HvDesktopOutput){mode_w*2,mode_h*2};
    return (HvDesktopOutput){w,h};
}
