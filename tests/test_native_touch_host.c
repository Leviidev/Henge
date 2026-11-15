#include "native_touch.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
typedef struct { int connected,reports,mapped,fail_report;uint8_t last[32],history[256][32]; } USB;
static int connect_usb(void *c,int v){((USB*)c)->connected=v;return 1;}
static int connected(void *c){return ((USB*)c)->connected;}
static int mapped(void *c){((USB*)c)->mapped++;return 1;}
static int report(void *c,const uint8_t *v){USB *u=c;assert(u->connected);if(u->fail_report)return 0;assert(u->reports<256);memcpy(u->history[u->reports++],v,32);memcpy(u->last,v,32);return 1;}
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
int main(void){
    USB u={0};HvNativeTouchUSB usb={.context=&u,.connect=connect_usb,.connected=connected,.report=report,.mapped=mapped};
    hv_native_touch_set_usb(&usb);uint32_t e=hv_native_touch_enable(1);
    hv_native_touch_progress(e-1,4);assert(hv_native_touch_status()==HV_TOUCH_WAITING);
    hv_native_touch_progress(e,3);assert(hv_native_touch_status()==HV_TOUCH_WAITING);
    assert(!hv_native_touch_usb_host_encoding(e));
    assert(hv_native_touch_usb_connect(e,1));assert(hv_native_touch_usb_mapped(e));
    assert(!hv_native_touch_usb_host_encoding(e-1));assert(hv_native_touch_usb_host_encoding(e));
    hv_native_touch_report(e,HV_TOUCH_READY);
    hv_native_touch_report(e,HV_TOUCH_WAITING);
    assert(hv_native_touch_status()==HV_TOUCH_READY); // late setup progress cannot downgrade readiness
    uint8_t id=7;double x=.25,y=.5;double start=now();
    assert(hv_native_touch_submit(e,&id,&x,&y,1));
    assert(now()-start<.05 && u.last[1]==3 && u.last[31]==1);
    // No guest HTTP GET, re-encode and PUT is needed for actual touch delivery.
    int n=u.reports;x=.75;assert(hv_native_touch_submit(e,&id,&x,&y,1));assert(u.reports==n+1);
    assert(!hv_native_touch_usb_report(e,u.last)); // one encoder, stale guest reports cannot resurrect touches
    assert(hv_native_touch_usb_host_encoding(e));assert(u.last[31]==1); // idempotent
    hv_native_touch_cancel(e-1);assert(u.last[1]==3);
    hv_native_touch_cancel(e);
    char json[1024];
    while(u.last[31] && now()-start<.5){hv_native_touch_report(e,HV_TOUCH_READY);assert(hv_native_touch_next(json,sizeof json));assert(strstr(json,"\"contacts\":[]"));}
    assert(u.last[31]==0 && u.connected && hv_native_touch_status()==HV_TOUCH_READY);
    assert(hv_native_touch_epoch()==e); // handoff must not remap USB or restart helper
    // A new Pencil stroke during a prior lift keeps its initial hit position,
    // even when movement and lift arrive before the settling interval ends.
    assert(hv_native_touch_submit(e,&id,&x,&y,1));
    hv_native_touch_cancel(e);
    int from=u.reports;id=8;x=.2;assert(hv_native_touch_submit(e,&id,&x,&y,1));
    x=.8;assert(hv_native_touch_submit(e,&id,&x,&y,1));
    assert(hv_native_touch_submit(e,NULL,NULL,NULL,0));
    double finish=now()+1;
    int saw_first=0,saw_motion=0;
    while(now()<finish) {
        hv_native_touch_report(e,HV_TOUCH_READY);assert(hv_native_touch_next(json,sizeof json));
        for(int j=from;j<u.reports;j++)for(int k=0;k<u.history[j][31];k++) {
            const uint8_t *f=u.history[j]+1+6*k;
            if(f[0]==3 && (f[2]|f[3]<<8)==6553)saw_first=1;
            if(f[0]==3 && (f[2]|f[3]<<8)==26214) { assert(saw_first);saw_motion=1; }
        }
        if(saw_motion && !u.last[31])break;
    }
    assert(saw_first && saw_motion && !u.last[31] && u.connected);
    n=u.reports;
    assert(hv_native_touch_submit(e,NULL,NULL,NULL,0));
    hv_native_touch_report(e,HV_TOUCH_READY);assert(hv_native_touch_next(json,sizeof json));
    assert(u.reports==n); // unchanged desktop has no USB report loop
    // A brief guest-helper delay no longer flips a touch-only phone to cursor
    // mode, while a stale UI sender still gets a real lift sequence.
    assert(hv_native_touch_submit(e,&id,&x,&y,1));
    struct timespec pause={0,800000000};nanosleep(&pause,NULL);
    assert(hv_native_touch_status()==HV_TOUCH_READY&&u.connected);
    hv_native_touch_report(e,HV_TOUCH_READY);
    double recovery=now();
    while(u.last[31]&&now()-recovery<.5)assert(hv_native_touch_next(json,sizeof json));
    assert(!u.last[31]&&hv_native_touch_epoch()==e);
    u.fail_report=1;
    assert(hv_native_touch_submit(e,&id,&x,&y,1));
    assert(hv_native_touch_status()==HV_TOUCH_TIMEOUT && hv_native_touch_epoch()!=e && !u.connected);
    hv_native_touch_enable(0);assert(!u.connected);assert(!hv_native_touch_usb_report(e,u.last));
    hv_native_touch_set_usb(NULL);
    puts("PASS host USB touch: direct delivery, stale-report rejection, non-disconnecting handoff, neutral drain and idle suppression");
}
