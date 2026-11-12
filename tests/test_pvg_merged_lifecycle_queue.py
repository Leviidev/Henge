"""Run the exact merged pump against lifecycle gates and simulated completions."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];source=(root/'devices/pvg_metal.m').read_text();start=source.index('- (void)pumpCommands {');end=source.index('\n}\n',start)+3;method=source[start:end]
commit_condition=source[source.index('if (layer_generation == generation && layer == target &&'):].split(') {',1)[0][4:]
assert 'presenter_barrier' in commit_condition
assert 'if (!screen_dirty || !layer || presenter_barrier' in source
assert 'atomic_load(&stopping) || presenter_barrier' in source
body='''#import <Foundation/Foundation.h>
#include <os/lock.h>
#include "lifecycle_gate.h"
#include "pvg_replay_queue.h"
#include "pvg_render_status.h"
HvLifecycleGate hv_app_lifecycle=HV_LIFECYCLE_INITIALIZER,hv_cpu_lifecycle=HV_LIFECYCLE_INITIALIZER;
pthread_mutex_t hv_lifecycle_state_mu=PTHREAD_MUTEX_INITIALIZER;
static void hv_pvg_lite_use_task_view(void*p,const void*v){(void)p;(void)v;}
@interface HvReplay:NSObject{@public
 _Atomic int stopping,ready,writes;HvOrderedReplay*ordered;HvReplayCommand*activeCommand;
 HvRenderStatus*renderStatus;void*lite;dispatch_queue_t worker,presenter;dispatch_group_t completions;
 BOOL pollScheduled,presenter_barrier;os_unfair_lock screen_lock;dispatch_semaphore_t encoded;
 NSObject*layer;uint64_t layer_generation;
}
- (void)pumpCommands;
- (void)kickPresenter:(BOOL)fresh;
- (BOOL)presentAttempt;
- (HvReplayReadiness)preflightCommand:(HvReplayCommand*)item;
- (void)performCommand:(HvReplayCommand*)item;
- (void)complain:(NSString*)text;
@end
@implementation HvReplay
- (instancetype)init{if((self=[super init])){ordered=[HvOrderedReplay new];renderStatus=[HvRenderStatus new];worker=dispatch_queue_create("authored-replay",DISPATCH_QUEUE_SERIAL);presenter=dispatch_queue_create("authored-presenter",DISPATCH_QUEUE_SERIAL);completions=dispatch_group_create();encoded=dispatch_semaphore_create(0);}return self;}
- (HvReplayReadiness)preflightCommand:(HvReplayCommand*)item{(void)item;return atomic_load(&ready)?HvReplayReady:HvReplayPark;}
- (void)performCommand:(HvReplayCommand*)item{(void)item;dispatch_group_enter(completions);if(atomic_fetch_add(&writes,1)==1)dispatch_semaphore_signal(encoded);}
- (void)complain:(NSString*)text{(void)text;}
- (void)kickPresenter:(BOOL)fresh{(void)fresh;}
- (BOOL)presentAttempt{NSObject*target=layer;uint64_t generation=layer_generation;BOOL committed=NO;
 os_unfair_lock_lock(&screen_lock);if(COMMIT_CONDITION){dispatch_group_enter(completions);committed=YES;}os_unfair_lock_unlock(&screen_lock);return committed;}

METHOD
@end
struct Result{_Atomic int success,cancel;dispatch_semaphore_t done;};
static void finished(void*ctx,int cancelled){struct Result*r=ctx;if(cancelled)atomic_fetch_add(&r->cancel,1);else{atomic_fetch_add(&r->success,1);hv_lifecycle_set_active(&hv_cpu_lifecycle,1);}dispatch_semaphore_signal(r->done);}
static HvReplayCommand*command(){HvReplayCommand*p=[HvReplayCommand new];uint32_t word=1;p->command=[NSData dataWithBytes:&word length:4];return p;}
static int await_control(dispatch_semaphore_t s){return (int)dispatch_semaphore_wait(s,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC));}
#define C(x)do{checks++;if(!(x)){fprintf(stderr,"FAIL %d\\n",__LINE__);return 1;}}while(0)
int main(){@autoreleasepool{unsigned checks=0;HvReplay*r=[HvReplay new];struct Result result={.done=dispatch_semaphore_create(0)};
 hv_lifecycle_set_active(&hv_cpu_lifecycle,0);C([r->ordered reserve:8]);HvReplayCommand*a=command(),*b=command(),*marker=[HvReplayCommand new];marker->barrier=finished;marker->opaque=&result;
 dispatch_sync(r->worker,^{[r->ordered enqueue:a];[r->ordered enqueue:b];[r->ordered enqueue:marker];[r pumpCommands];});
 C(atomic_load(&r->writes)==0);C(!atomic_load(&result.success));char msg[128];C([r->renderStatus copyMessage:msg length:sizeof msg]==1);
 hv_lifecycle_set_active(&hv_app_lifecycle,0);dispatch_semaphore_t ui=dispatch_semaphore_create(0);dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{char out[64];[r->renderStatus copyMessage:out length:sizeof out];dispatch_semaphore_signal(ui);});C(!await_control(ui));
 atomic_store(&r->ready,1);hv_lifecycle_set_active(&hv_app_lifecycle,1);C(!await_control(r->encoded));C(atomic_load(&r->writes)==2);C(!hv_lifecycle_allowed(&hv_cpu_lifecycle));C(!atomic_load(&result.success));
 dispatch_group_leave(r->completions);dispatch_group_leave(r->completions);C(!await_control(result.done));C(atomic_load(&result.success)==1&&atomic_load(&result.cancel)==0);C(hv_lifecycle_allowed(&hv_cpu_lifecycle));
 dispatch_sync(r->worker,^{});C(!r->ordered->entries.count);C(!atomic_load(&r->ordered->reserved));

 /* A drawable may already be prepared before the barrier closes final admission.
    Keep one prior completion alive so a producer cannot hide behind a zero group. */
 HvReplay*p=[HvReplay new];p->layer=[NSObject new];struct Result mapping={.done=dispatch_semaphore_create(0)};
 dispatch_group_enter(p->completions);HvReplayCommand*map=[HvReplayCommand new];map->barrier=finished;map->opaque=&mapping;
 dispatch_sync(p->worker,^{[p->ordered enqueue:map];[p pumpCommands];});C(p->presenter_barrier);
 __block BOOL preparedCommitted=NO;dispatch_semaphore_t prepared=dispatch_semaphore_create(0),allowFinal=dispatch_semaphore_create(0),attempted=dispatch_semaphore_create(0);
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{dispatch_semaphore_signal(prepared);dispatch_semaphore_wait(allowFinal,DISPATCH_TIME_FOREVER);preparedCommitted=[p presentAttempt];dispatch_semaphore_signal(attempted);});
 C(!await_control(prepared));dispatch_semaphore_signal(allowFinal);C(!await_control(attempted));
 unsigned entered=preparedCommitted;for(unsigned i=0;i<63;i++)entered+=[p presentAttempt];
 C(entered==(NEGATIVE?64:0));dispatch_group_leave(p->completions);
 if(NEGATIVE){C(dispatch_semaphore_wait(mapping.done,dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC))!=0);for(unsigned i=0;i<entered;i++)dispatch_group_leave(p->completions);}
 C(!await_control(mapping.done));dispatch_sync(p->worker,^{});C(!p->presenter_barrier);C(atomic_load(&mapping.success)==1);

 /* An already-preparing presenter must leave its serial queue before the
    empty-group notification can release mappings. */
 HvReplay*z=[HvReplay new];z->layer=[NSObject new];struct Result preparingMap={.done=dispatch_semaphore_create(0)};
 dispatch_semaphore_t drawing=dispatch_semaphore_create(0),finishPreparing=dispatch_semaphore_create(0);__block BOOL lateCommit=NO;
 dispatch_async(z->presenter,^{dispatch_semaphore_signal(drawing);dispatch_semaphore_wait(finishPreparing,DISPATCH_TIME_FOREVER);lateCommit=[z presentAttempt];if(lateCommit)dispatch_group_leave(z->completions);});C(!await_control(drawing));
 HvReplayCommand*preparedMap=[HvReplayCommand new];preparedMap->barrier=finished;preparedMap->opaque=&preparingMap;
 dispatch_sync(z->worker,^{[z->ordered enqueue:preparedMap];[z pumpCommands];});
 C(dispatch_semaphore_wait(preparingMap.done,dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC))!=0);
 dispatch_semaphore_signal(finishPreparing);C(!await_control(preparingMap.done));dispatch_sync(z->worker,^{});
 C(lateCommit==NEGATIVE);C(!z->presenter_barrier);
 HvReplay*q=[HvReplay new];struct Result cancelled={.done=dispatch_semaphore_create(0)};hv_lifecycle_set_active(&hv_cpu_lifecycle,0);C([q->ordered reserve:4]);HvReplayCommand*c=command(),*stopMarker=[HvReplayCommand new];stopMarker->barrier=finished;stopMarker->opaque=&cancelled;
 dispatch_sync(q->worker,^{[q->ordered enqueue:c];[q->ordered enqueue:stopMarker];[q pumpCommands];});hv_lifecycle_cancel(&hv_app_lifecycle);C(!await_control(cancelled.done));C(atomic_load(&cancelled.cancel)==1&&!atomic_load(&cancelled.success));C(atomic_load(&q->writes)==0);C(!hv_lifecycle_allowed(&hv_cpu_lifecycle));dispatch_sync(q->worker,^{});C(!atomic_load(&q->ordered->reserved));C(q->ordered->stopped);
 printf("%u exact merged pump/lifecycle/drain/host-status/cancellation checks passed; simulated completions, no GPU\\n",checks);return 0;
}}
'''.replace('METHOD',method).replace('COMMIT_CONDITION',commit_condition)
for negative in [False,True]:
 with tempfile.TemporaryDirectory()as t:
  p=Path(t);variant=body.replace('NEGATIVE','1' if negative else '0')
  if negative:variant=variant.replace('&& !presenter_barrier','')
  (p/'test.m').write_text(variant)
  subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-Wno-unused-function','-I'+str(root/'devices'),'-I'+str(root/'host'),str(p/'test.m'),'-framework','Foundation','-o',str(p/'test')],check=True)
  subprocess.run([str(p/'test')],timeout=15,check=True)
print('Presenter admission positive and old-condition negative control passed; no GPU')
