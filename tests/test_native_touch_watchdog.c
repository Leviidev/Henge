#include "native_touch.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct {int connected,disconnects,reports;unsigned char last[32];} USB;
static int connect_usb(void *p,int on){USB*u=p;if(u->connected&&!on)u->disconnects++;u->connected=on;return 1;}
static int connected(void*p){return ((USB*)p)->connected;}
static int report(void*p,const uint8_t*v){USB*u=p;assert(u->connected);u->reports++;memcpy(u->last,v,32);return 1;}
static void idle_has_no_stall(void) {
 USB u={0};HvNativeTouchUSB usb={.context=&u,.connect=connect_usb,.connected=connected,.report=report,.mapped=connected};
 hv_native_touch_test_time(50);hv_native_touch_set_usb(&usb);uint32_t e=hv_native_touch_enable(1);
 assert(hv_native_touch_usb_connect(e,1));assert(hv_native_touch_usb_host_encoding(e));hv_native_touch_report(e,HV_TOUCH_READY);
 assert(hv_native_touch_status()==HV_TOUCH_READY);
 int before=u.reports;
 for(double t=50.25;t<55;t+=.25){hv_native_touch_test_time(t);hv_native_touch_report(e,HV_TOUCH_READY);assert(hv_native_touch_status()==HV_TOUCH_READY);}
 assert(u.reports==before && u.connected && !u.disconnects);
 uint8_t id=3;double x=.2,y=.4;
 assert(hv_native_touch_submit(e,&id,&x,&y,1));
 assert(u.reports==before+1 && u.last[1]==3 && u.last[31]==1);
 hv_native_touch_enable(0);hv_native_touch_set_usb(NULL);
 puts("PASS touch idle watchdog: no idle cancellation/wakeup, first contact immediate after long idle; held-contact timeout retained");
}
int main(void){
 idle_has_no_stall();
 USB u={0};HvNativeTouchUSB usb={.context=&u,.connect=connect_usb,.connected=connected,.report=report,.mapped=connected};
 hv_native_touch_test_time(100);hv_native_touch_set_usb(&usb);uint32_t e=hv_native_touch_enable(1);
 hv_native_touch_test_time(106);assert(hv_native_touch_status()==HV_TOUCH_WAITING); // no enumeration storm after5s
 hv_native_touch_test_time(110);assert(hv_native_touch_usb_connect(e,1));assert(hv_native_touch_usb_host_encoding(e));hv_native_touch_report(e,HV_TOUCH_READY);
 uint8_t id=1;double x=.2,y=.3;assert(hv_native_touch_submit(e,&id,&x,&y,1));assert(u.last[31]);
 for(double t=110.5;t<112.6;t+=0.5){hv_native_touch_test_time(t);assert(hv_native_touch_submit(e,&id,&x,&y,1));}
 hv_native_touch_test_time(112.6);assert(hv_native_touch_status()==HV_TOUCH_STALLED);assert(hv_native_touch_direct_mapping());assert(u.connected&&!(u.last[1]&1)&&!u.disconnects&&hv_native_touch_epoch()==e);
 hv_native_touch_test_time(112.7);assert(hv_native_touch_status()==HV_TOUCH_STALLED);assert(!u.last[31]);
 assert(!hv_native_touch_submit(e,&id,&x,&y,1));hv_native_touch_report(e-1,HV_TOUCH_READY);assert(hv_native_touch_status()==HV_TOUCH_STALLED);
 hv_native_touch_report(e,HV_TOUCH_READY);assert(hv_native_touch_status()==HV_TOUCH_READY);assert(!hv_native_touch_submit(e,&id,&x,&y,1));
 assert(hv_native_touch_submit(e,NULL,NULL,NULL,0));assert(hv_native_touch_submit(e,&id,&x,&y,1));
 hv_native_touch_test_time(143);assert(hv_native_touch_status()==HV_TOUCH_TIMEOUT);assert(!hv_native_touch_direct_mapping());assert(!u.connected&&u.disconnects==1&&hv_native_touch_epoch()!=e);
 e=hv_native_touch_enable(1);hv_native_touch_test_time(174);assert(hv_native_touch_status()==HV_TOUCH_TIMEOUT);
 e=hv_native_touch_enable(1);hv_native_touch_progress(e,3);hv_native_touch_failure(e-1,3,-1001);assert(hv_native_touch_status()==HV_TOUCH_WAITING);
 hv_native_touch_failure(e,3,-1001);assert(hv_native_touch_status()==HV_TOUCH_DEVICE);
 hv_native_touch_test_time(200);e=hv_native_touch_enable(1);
 assert(hv_native_touch_usb_connect(e,1));assert(hv_native_touch_usb_host_encoding(e));hv_native_touch_report(e,HV_TOUCH_READY);
 hv_native_touch_test_time(203);assert(hv_native_touch_status()==HV_TOUCH_STALLED);
 hv_native_touch_enable(0);hv_native_touch_report(e,HV_TOUCH_READY);
 assert(hv_native_touch_status()==HV_TOUCH_OFF && !u.connected && !hv_native_touch_direct_mapping());
 hv_native_touch_set_usb(NULL);
 char command[1024];assert(hv_native_touch_next(command,sizeof command));
 assert(hv_native_touch_helper_alive());
 hv_native_touch_test_time(206);assert(!hv_native_touch_helper_alive());
 puts("PASS touch watchdog: mapping-preserving grace, neutral boundary, stale epoch rejection, bounded setup/dead-helper timeout and guest failure details");
}
