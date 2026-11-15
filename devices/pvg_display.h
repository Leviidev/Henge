#ifndef HENGE_PVG_DISPLAY_H
#define HENGE_PVG_DISPLAY_H
#include <stdint.h>
#include <string.h>
#define HV_PVG_DISPLAY_PORTS 2
typedef struct HvPvgDisplayMode {
    uint32_t width, height, width_mm, height_mm, hz;
} HvPvgDisplayMode;
typedef struct HvPvgDisplayState {
    uint64_t page, swaps;
    uint32_t sequence, port;
    HvPvgDisplayMode mode;
    int connected;
} HvPvgDisplayState;
static inline int hv_pvg_mode_valid(HvPvgDisplayMode m) {
    return m.width >= 320 && m.height >= 240 && m.width <= 8192 && m.height <= 8192 &&
        (uint64_t)m.width * m.height <= 33554432 && m.width_mm <= 65535 && m.height_mm <= 65535 &&
        m.hz >= 24 && m.hz <= 120;
}
/* Every offset belongs to this port's own 16KB guest page. The existing port-0
   wire layout is preserved; publication of the change flag is last. */
static inline void hv_pvg_display_publish(HvPvgDisplayState *s, uint8_t *d) {
    uint32_t w = s->mode.width, h = s->mode.height;
    uint32_t mmw = 400, mmh = 400 * h / w;
    if(s->mode.width_mm && s->mode.height_mm){mmw=s->mode.width_mm;mmh=s->mode.height_mm;}
#define HV_PUT32(o,v) do { uint32_t x_=(uint32_t)(v);memcpy(d+(o),&x_,4); } while(0)
#define HV_PUTF(o,v) do { float x_=(float)(v);memcpy(d+(o),&x_,4); } while(0)
    HV_PUT32(0x00,s->connected ? 1 : 0);
    /* AppleParavirtDisplay::setupSharedState (27.2, line 314) validates
       this 16-bit port against its requested port before reading the modes.
       Zero happened to work for the primary display only. */
    uint16_t port=(uint16_t)s->port;memcpy(d+0x12,&port,sizeof port);
    HV_PUT32(0x14,mmh<<16|mmw);HV_PUT32(0x18,0x01000100);HV_PUT32(0x1c,0x400);HV_PUT32(0x20,3);
    HV_PUTF(0x24,mmw);HV_PUTF(0x28,mmh);
    HV_PUT32(0x208,s->connected ? 1 : 0);HV_PUT32(0x210,h<<16|w);HV_PUT32(0x214,s->mode.hz<<16);
    HV_PUTF(0xa10,1);HV_PUTF(0xa24,1);HV_PUTF(0xa38,1);d[0xa73]=1;
    int initial=s->sequence==0;
    if(!++s->sequence)++s->sequence;
    HV_PUT32(0x200,s->sequence);d[0xfa9]=1;HV_PUT32(0xfc0,1);
    if(initial)__atomic_store_n((uint32_t *)(d+0x100),4,__ATOMIC_RELEASE);
    else __atomic_fetch_or((uint32_t *)(d+0x100),4,__ATOMIC_RELEASE);
#undef HV_PUT32
#undef HV_PUTF
}
#endif
