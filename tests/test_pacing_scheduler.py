"""Exercise the production deferred-present scheduler with real dispatch queues."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
s=(root/'devices/pvg_metal.m').read_text()
a=s.index('- (void)kickPresenter:(BOOL)fresh {');level=1;i=s.index('{',a)+1;start=i
while level:
 if s[i]=='{':level+=1
 if s[i]=='}':level-=1
 i+=1
method=s[a:i]
pre=r'''
#import <Foundation/Foundation.h>
#include <os/lock.h>
#include <unistd.h>
#include <time.h>
#include <assert.h>
#include <stdatomic.h>
#include "frame_pacing.h"
static double now_seconds(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC)*1e-9; }
@interface Harness:NSObject { @public
 os_unfair_lock screen_lock; id layer, screen_tex;
 BOOL presenter_running, drawable_retry_pending, pacing_pending,display_driven,display_quiesced;
 _Atomic int stopping; _Atomic unsigned presentation_inflight;
 double drawable_retry_cooldown, drawable_retry_deadline;
 uint64_t layer_generation, screen_requests;
 dispatch_queue_t presenter; HvFramePacing frame_pacing; int pacing_fps;
 unsigned draws; dispatch_semaphore_t delivered;
}
-(void)updatePacingPolicy;
-(void)presentLoop;
-(void)kickPresenter:(BOOL)fresh;
@end
@implementation Harness
-(void)updatePacingPolicy {}
-(void)presentLoop { os_unfair_lock_lock(&screen_lock);draws++;hv_pacing_presented(&frame_pacing,now_seconds(),pacing_fps);presenter_running=NO;os_unfair_lock_unlock(&screen_lock);dispatch_semaphore_signal(delivered); }
'''
post=r'''
@end
static void kick(Harness *h) { os_unfair_lock_lock(&h->screen_lock);[h kickPresenter:YES];os_unfair_lock_unlock(&h->screen_lock); }
int main(void) { @autoreleasepool {
 Harness *h=[Harness new];h->screen_lock=OS_UNFAIR_LOCK_INIT;
 h->layer=[NSObject new];h->screen_tex=[NSObject new];h->pacing_fps=30;
 h->delivered=dispatch_semaphore_create(0);
 h->presenter=dispatch_queue_create("test.pacer",DISPATCH_QUEUE_SERIAL);
 h->frame_pacing.next=now_seconds()+0.04;
 os_unfair_lock_lock(&h->screen_lock);
 for(int i=0;i<1000;i++)[h kickPresenter:YES];
 os_unfair_lock_unlock(&h->screen_lock);
 assert(dispatch_semaphore_wait(h->delivered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 dispatch_sync(h->presenter,^{});
 printf("pacing scheduler: draws=%u pending=%d deferred=%llu\n",h->draws,h->pacing_pending,h->frame_pacing.coalesced);
 assert(h->draws==1 && !h->pacing_pending && h->frame_pacing.coalesced>=1);
 assert(dispatch_semaphore_wait(h->delivered,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))!=0);
 dispatch_sync(h->presenter,^{});assert(h->draws==1);
 os_unfair_lock_lock(&h->screen_lock);h->frame_pacing.next=now_seconds()+0.04;os_unfair_lock_unlock(&h->screen_lock);
 kick(h);
 os_unfair_lock_lock(&h->screen_lock);h->layer_generation++;h->pacing_pending=NO;h->frame_pacing.next=0;os_unfair_lock_unlock(&h->screen_lock);
 assert(dispatch_semaphore_wait(h->delivered,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))!=0);
 dispatch_sync(h->presenter,^{});assert(h->draws==1);
 kick(h);assert(dispatch_semaphore_wait(h->delivered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
 dispatch_sync(h->presenter,^{});assert(h->draws==2);
 atomic_store(&h->presentation_inflight,2);kick(h);
 assert(dispatch_semaphore_wait(h->delivered,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC))!=0);
 atomic_store(&h->presentation_inflight,1);kick(h);
 assert(!dispatch_semaphore_wait(h->delivered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)));
 dispatch_sync(h->presenter,^{});assert(h->draws==3);
 puts("production presenter scheduler: 1000 events coalesced, final frame retained, no idle timer, stale target cancellation and reconnect passed");
} }
'''
b=root/'build';b.mkdir(exist_ok=True);p=b/'test_pacing_scheduler.m';p.write_text(pre+method+post)
subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-Wall','-Wextra','-Werror','-I'+str(root/'devices'),str(p),'-framework','Foundation','-o',str(b/'test_pacing_scheduler')],check=True)
subprocess.run([str(b/'test_pacing_scheduler')],check=True,timeout=10)
