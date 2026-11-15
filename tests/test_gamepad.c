#include "gamepad.h"
#include "gamepad_ds4.h"
#include <assert.h>
#include <stdio.h>
static void descriptor_check(void) {
    unsigned bits[3][256]={{0}},size=0,count=0,report=0;
    for(size_t at=0;at<sizeof hv_ds4_descriptor;) {
        uint8_t prefix=hv_ds4_descriptor[at++];assert(prefix!=0xfe);
        unsigned n=prefix&3;if(n==3)n=4;
        assert(at+n<=sizeof hv_ds4_descriptor);unsigned value=0;
        for(unsigned i=0;i<n;i++)value|=(unsigned)hv_ds4_descriptor[at++]<<(8*i);
        unsigned type=(prefix>>2)&3,tag=prefix>>4;
        if(type==1) {if(tag==7)size=value;else if(tag==8){report=value;assert(report<256);}else if(tag==9)count=value;}
        if(type==0 && (tag==8 || tag==9 || tag==11))bits[tag==8?0:tag==9?1:2][report]+=size*count;
    }
    assert(bits[0][1]==63*8 && bits[1][5]==31*8);
    assert(bits[2][2]==36*8 && bits[2][0x12]==15*8 && bits[2][0xa3]==48*8);
}
int main(void) {
    descriptor_check();
    uint8_t report[HV_GAMEPAD_BYTES];hv_gamepad_neutral(report);
    assert(report[2]==8);for(unsigned i=0;i<sizeof report;i++)if(i!=2)assert(report[i]==0);
    int16_t axes[4]={-32768,32767,-1,0};hv_gamepad_pack(report,0x3ff,1,axes,0,255);
    assert(report[0]==255 && report[1]==3 && report[2]==1);
    assert(report[3]==1 && report[4]==128 && report[5]==255 && report[6]==127);
    assert(report[11]==0 && report[12]==255);
    hv_gamepad_pack(report,0,99,axes,1,2);assert(report[2]==8);
    uint8_t native[64], feature[64];
    hv_gamepad_neutral(report);hv_ds4_pack(native,report,0);
    assert(native[0]==1 && native[1]==128 && native[2]==128 && native[3]==128 && native[4]==128);
    assert(native[5]==8 && native[6]==0 && native[7]==0 && native[35]==0x80 && native[39]==0x80);
    int16_t extremes[4]={-32767,32767,0,-32768};hv_gamepad_pack(report,0xfff,7,extremes,123,255);
    hv_ds4_pack(native,report,63);
    assert(native[1]==0 && native[2]==255 && native[3]==128 && native[4]==0);
    assert(native[5]==0xf7 && native[6]==255 && native[7]==255 && native[8]==123 && native[9]==255);
    assert(hv_ds4_feature(2,feature,sizeof feature)==37 && (feature[7]|feature[8]<<8)==9000);
    assert(hv_ds4_feature(0x12,feature,sizeof feature)==16 && feature[6]==2);
    assert(hv_ds4_feature(0x81,feature,sizeof feature)==7);
    assert(hv_ds4_feature(0xa3,feature,sizeof feature)==49);
    assert(hv_ds4_feature(0xa3,feature,48)==-1 && hv_ds4_feature(0xff,feature,64)==-1);
    assert(sizeof hv_ds4_descriptor==507);
    puts("PS4-compatible: centered/extreme axes, native button order, triggers, counters, inactive touchpad and feature bounds passed");
    puts("gamepad: signed sticks, bounded hat, buttons, triggers and neutral report passed");
}
