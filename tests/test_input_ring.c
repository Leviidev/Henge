#include "input_ring.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    uint8_t owners[3]={0};int state=0;
    assert(hv_input_button_owner(owners,0,4,1,&state)&&state);
    assert(!hv_input_button_owner(owners,0,5,1,&state)&&state);
    assert(!hv_input_button_owner(owners,0,4,0,&state)&&state);
    assert(hv_input_button_owner(owners,0,5,0,&state)&&!state);
    assert(!hv_input_button_owner(owners,0,4,0,&state));
    assert(hv_input_button_owner(owners,1,7,1,&state)&&state);
    assert(!hv_input_button_owner(owners,1,1,1,&state));
    assert(!hv_input_button_owner(owners,1,7,0,&state)&&state);
    assert(hv_input_button_owner(owners,1,1,0,&state)&&!state);
    assert(!hv_input_button_owner(owners,1,8,1,&state));
    HvInputEvent ring[HV_VINPUT_RING];
    uint32_t head=0,tail=0;uint8_t buttons=0;uint64_t dropped=0;
    hv_input_enqueue(ring,&head,&tail,&buttons,&dropped,1,1,0x110,1);
    for(unsigned i=1;i<HV_VINPUT_RING;i++)hv_input_enqueue(ring,&head,&tail,&buttons,&dropped,1,2,0,1);
    // A release at exact capacity must survive, and all guest buttons reconcile.
    hv_input_enqueue(ring,&head,&tail,&buttons,&dropped,1,1,0x110,0);
    assert(dropped==HV_VINPUT_RING && tail-head==4 && buttons==0);
    for(unsigned b=0;b<3;b++) {
        HvInputEvent e=ring[(head+b)%HV_VINPUT_RING];
        assert(e.type==1 && e.code==0x110+b && e.value==0);
    }
    assert(ring[(head+3)%HV_VINPUT_RING].type==0);
    // Preserve a genuine held right button through motion saturation.
    head=tail;
    hv_input_enqueue(ring,&head,&tail,&buttons,&dropped,1,1,0x111,1);
    for(unsigned i=1;i<HV_VINPUT_RING;i++)hv_input_enqueue(ring,&head,&tail,&buttons,&dropped,1,0,0,0);
    hv_input_enqueue(ring,&head,&tail,&buttons,&dropped,1,2,1,-7);
    assert(tail-head==5 && ring[(head+1)%HV_VINPUT_RING].value==1);
    assert((int32_t)ring[(head+4)%HV_VINPUT_RING].value==-7);
    hv_input_enqueue(ring,&head,&tail,&buttons,&dropped,1,1,0x111,0);
    assert(buttons==0 && ring[(tail-1)%HV_VINPUT_RING].value==0);
    // Unsigned index wrap retains capacity arithmetic.
    head=tail=UINT32_MAX-2;
    for(unsigned i=0;i<HV_VINPUT_RING+2;i++)hv_input_enqueue(ring,&head,&tail,&buttons,&dropped,1,0,0,0);
    assert(tail-head<HV_VINPUT_RING);
    puts("PASS input ring: release overflow, held-state reconciliation, motion and index wrap");
}
