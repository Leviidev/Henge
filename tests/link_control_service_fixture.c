/* Native input/GPU boundary spy only. The production host/client services,
   schema, TLS transport, pairing and decode worker execute without a VM. */
#include "link_control_service_fixture.h"
#include <stdatomic.h>
#include <Block.h>
static HvPvgLinkFrameHandler primary_handler;
static _Atomic unsigned keys,releases,video,displays,held;
static _Atomic int vm_state = 1;
int henge_vm_state(void){return atomic_load(&vm_state);}
void henge_vm_mouse_move(int dx,int dy){(void)dx;(void)dy;}
void henge_vm_mouse_scroll(int dx,int dy){(void)dx;(void)dy;}
void henge_vm_input_key(unsigned source,uint8_t usage,int down){
    (void)usage;if(source==1){atomic_fetch_add(&keys,1);atomic_store(&held,!!down);}
}
void henge_vm_input_button(unsigned source,int button,int down){(void)source;(void)button;(void)down;}
void henge_vm_input_release(unsigned source){if(source==1){atomic_store(&held,0);atomic_fetch_add(&releases,1);}}
void henge_vm_mirror_refresh(void) {}
void hv_pvg_link_set_primary_frame_handler(HvPvgLinkFrameHandler handler){
    if(primary_handler)Block_release(primary_handler);
    primary_handler=handler ? Block_copy(handler) : NULL;
    if(handler)atomic_fetch_add(&video,1);
}
void test_control_frame(void *texture,void *queue){if(primary_handler)primary_handler(texture,queue,0,NULL,0,0,0,0);}
void henge_vm_link_connected(int connected){(void)connected;}
int henge_vm_set_link_display(uint32_t w,uint32_t h,uint32_t wm,uint32_t hm,uint32_t hz){
    (void)w;(void)h;(void)wm;(void)hm;(void)hz;atomic_fetch_add(&displays,1);return 0;
}
void hv_pvg_link_set_frame_handler(HvPvgLinkFrameHandler handler){if(handler)atomic_fetch_add(&video,1);}
unsigned test_control_keys(void){return atomic_load(&keys);}
unsigned test_control_releases(void){return atomic_load(&releases);}
unsigned test_control_video(void){return atomic_load(&video);}
unsigned test_control_displays(void){return atomic_load(&displays);}
unsigned test_control_held(void){return atomic_load(&held);}
void test_control_paused(int enabled){atomic_store(&vm_state,enabled ? 4 : 1);}

int henge_vm_display_mode(unsigned port,HengeVmDisplayMode *out){
    if(port!=0)return -1;
    *out=(HengeVmDisplayMode){320,240,70,52,60};return 0;
}
