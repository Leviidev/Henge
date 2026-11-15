#include "pvg_display.h"
#include <assert.h>
#include <stdio.h>
static uint16_t u16(const uint8_t *p){uint16_t v;memcpy(&v,p,2);return v;}
static uint32_t u32(const uint8_t *p){uint32_t v;memcpy(&v,p,4);return v;}
int main(void){
    uint8_t a[0x4000] __attribute__((aligned(16)))={0},b[0x4000] __attribute__((aligned(16)))={0};
    HvPvgDisplayState primary={.connected=1,.mode={2752,2064,265,199,120}};
    HvPvgDisplayState second={.port=1,.connected=1,.mode={1920,1350,160,113,60}};
    assert(hv_pvg_mode_valid(primary.mode)&&hv_pvg_mode_valid(second.mode));
    *(uint32_t *)(a+0x100)=8; /* original port-0 initialization replaces old status bits */
    hv_pvg_display_publish(&primary,a);hv_pvg_display_publish(&second,b);
    /* Reproduce the actual guest's setupSharedState contract, not merely
       whether a host mode/codec was initialized. The old second page fails. */
    assert(u16(a+0x12)==0 && u16(b+0x12)==1);
    uint8_t broken[0x4000];memcpy(broken,b,sizeof broken);broken[0x12]=broken[0x13]=0;
    assert(u16(broken+0x12)!=1);
    assert(u32(a+0x210)==(2064u<<16|2752)&&u32(b+0x210)==(1350u<<16|1920));
    assert(u32(a+0x214)==120u<<16&&u32(b+0x214)==60u<<16);
    uint8_t unchanged[sizeof a];memcpy(unchanged,a,sizeof a);
    second.connected=0;hv_pvg_display_publish(&second,b);
    assert(!u32(b)&&!u32(b+0x208)&&u32(b+0x200)==2&&u16(b+0x12)==1);
    assert(!memcmp(a,unchanged,sizeof a));second.connected=1;hv_pvg_display_publish(&second,b);
    assert(u32(b)==1&&u32(b+0x208)==1&&u32(b+0x200)==3&&(u32(b+0x100)&4));
    second.sequence=UINT32_MAX;hv_pvg_display_publish(&second,b);assert(second.sequence==1);
    HvPvgDisplayMode bad=second.mode;bad.width=UINT32_MAX;assert(!hv_pvg_mode_valid(bad));
    bad=second.mode;bad.height=0;assert(!hv_pvg_mode_valid(bad));bad=second.mode;bad.hz=240;assert(!hv_pvg_mode_valid(bad));
    puts("PVG per-port state: independent modes/Hz/pages, disconnect/reconnect sequence, guest port-identity assertion, publication, wrap and bounds passed");
}
