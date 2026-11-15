#include "frame_pacing.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 assert(hv_pacing_fps(0,0,1)==0); assert(hv_pacing_fps(0,2,1)==30);
 assert(hv_pacing_power_fps(0,0,0,1,1)==60);
 assert(hv_pacing_power_fps(0,0,0,1,0)==0);
 assert(hv_pacing_power_fps(30,0,0,1,1)==30);
 assert(hv_pacing_power_fps(0,3,1,1,1)==20);
 assert(hv_pacing_power_fps(0,0,0,0,1)==0);
 assert(hv_pacing_fps(60,3,1)==20); assert(hv_pacing_fps(30,0,1)==30);
 assert(hv_pacing_fps(0,3,0)==0); assert(hv_pacing_fps(60,2,0)==60);
 HvFramePacing p={0};unsigned draws=0;
 for(int i=0;i<10000;i++) {
  double t=i/1000.0;
  if(hv_pacing_delay(&p,t,30)<=0) {hv_pacing_presented(&p,t,30);draws++;}
 }
 assert(draws>=290 && draws<=300); // 1000 updates/sec, about 30 submissions/sec
 assert(hv_pacing_delay(&p,10,0)==0 && p.next==0);
 hv_pacing_presented(&p,11,60); assert(hv_pacing_delay(&p,12,60)==0);
 assert(hv_pacing_delay(&p,11,60)>0); // monotonic input; finite deferred wake
 /* Encoding finishes 2ms after each vblank. A commit-relative second gate
    rejects the next perfectly valid 60Hz pulse: document the regression. */
 HvFramePacing competing={0};unsigned admitted=0;
 for(int frame=0;frame<120;frame++){
  double pulse=frame/60.0;
  if(hv_pacing_delay(&competing,pulse,60)<=0){admitted++;hv_pacing_presented(&competing,pulse+0.002,60);}
 }
 assert(admitted==60);
 puts("frame pacing: limits, thermal transitions, protection override, burst coalescing and idle eligibility passed");
}
