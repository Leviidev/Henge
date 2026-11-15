#include "../devices/desktop_geometry.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
int main(void) {
    HvDesktopOutput s=hv_desktop_output(1280,960,1280,960,2);
    assert(s.width==2560 && s.height==1920);
    s=hv_desktop_output(1024,768,1280,960,2); // macOS scaled surface, fixed canvas
    assert(s.width==2560 && s.height==1920);
    s=hv_desktop_output(1280,900,1280,900,2); // Duo proportional target
    assert(s.width==2560 && s.height==1800);
    for(int scale=0;scale<4;scale++)for(unsigned w=0;w<8193;w+=31){
        s=hv_desktop_output(1280,960,w,960,scale);
        assert(s.width==(scale==2 && w && w<=4096?w*2:1280));
    }
    s=hv_desktop_output(2560,1920,UINT_MAX,UINT_MAX,2);
    assert(s.width==2560&&s.height==1920); // no multiplication overflow
    puts("PASS Desktop MetalFX geometry: fixed 2560x1920 canvas, Duo aspect, scaled surfaces and overflow guards");
}
