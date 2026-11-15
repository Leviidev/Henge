#include "native_touch_encoder.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    HvTouchEncoder e={0};HvTouchFrame f={.count=1,.ids={9},.x={.25},.y={.5}};
    uint8_t r[32];int consumed;
    assert(hv_touch_encoder_step(&e,&f,1,&consumed,r)&&consumed&&r[1]==3&&r[2]==1&&r[31]==1);
    // Position updates have no 16ms polling or 60ms membership delay.
    f.x[0]=.75;
    assert(hv_touch_encoder_step(&e,&f,1.001,&consumed,r)&&consumed&&r[3]==255&&r[4]==95);
    HvTouchFrame lift={0};
    assert(!hv_touch_encoder_step(&e,&lift,1.002,&consumed,r)&&!consumed);
    assert(hv_touch_encoder_step(&e,&lift,1.061,&consumed,r)&&consumed&&r[1]==2);
    assert(hv_touch_encoder_step(&e,NULL,1.122,&consumed,r)&&r[31]==0);
    assert(hv_touch_encoder_due(&e,0,1.122)==0);
    f.count=5;for(int i=0;i<5;i++){f.ids[i]=(uint8_t)(i+10);f.x[i]=.5;f.y[i]=.5;}
    assert(hv_touch_encoder_step(&e,&f,2,&consumed,r)&&consumed&&r[31]==5);
    hv_touch_encoder_cancel(&e);
    assert(hv_touch_encoder_step(&e,NULL,2.061,&consumed,r)&&r[1]==2&&r[31]==5);
    // All occupied slots pack first, with stable HID ids after selective lift.
    assert(hv_touch_encoder_step(&e,NULL,2.122,&consumed,r)&&r[31]==0);
    f.count=2;assert(hv_touch_encoder_step(&e,&f,3,&consumed,r)&&consumed);
    f.count=1;f.ids[0]=11;
    assert(hv_touch_encoder_step(&e,&f,3.061,&consumed,r)&&consumed);
    assert(hv_touch_encoder_step(&e,NULL,3.122,&consumed,r)&&r[31]==1&&r[2]==2);
    // Same-id short re-tap cannot re-use a slot before the lifted report retires.
    f.count=0;assert(hv_touch_encoder_step(&e,&f,3.2,&consumed,r)&&consumed);
    f.count=1;f.ids[0]=11;
    (void)hv_touch_encoder_step(&e,&f,3.22,&consumed,r);assert(!consumed);
    assert(hv_touch_encoder_step(&e,&f,3.261,&consumed,r)&&consumed&&r[1]==3);
    // Replace all five contacts: lift before waiting for free retiring slots.
    memset(&e,0,sizeof e);f.count=5;
    for(unsigned i=0;i<5;i++)f.ids[i]=(uint8_t)(i+1);
    assert(hv_touch_encoder_step(&e,&f,4,&consumed,r)&&consumed);
    for(unsigned i=0;i<5;i++)f.ids[i]=(uint8_t)(i+20);
    assert(hv_touch_encoder_step(&e,&f,4.061,&consumed,r)&&!consumed&&r[1]==2);
    assert(hv_touch_encoder_step(&e,&f,4.122,&consumed,r)&&consumed&&r[1]==3&&r[31]==5);
    puts("PASS host touch encoder: immediate motion, short taps, stable packed slots, lift retention and cancellation");
}
