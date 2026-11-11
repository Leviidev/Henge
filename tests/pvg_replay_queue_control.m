#import <Foundation/Foundation.h>
#include "pvg_replay_queue.h"
static unsigned checks;static void done(void *ctx,int cancelled){int *v=ctx;v[cancelled?1:0]++;}
#define C(...) do{checks++;if(!(__VA_ARGS__)){fprintf(stderr,"FAIL %d\n",__LINE__);return 1;}}while(0)
static HvReplayCommand *command(uint32_t stamp){HvReplayCommand*p=[HvReplayCommand new];p->command=[NSData dataWithBytes:&stamp length:4];return p;}
int main(){@autoreleasepool{
 HvOrderedReplay *q=[HvOrderedReplay new];__block BOOL ready=NO;__block int writes=0;NSMutableArray *stamps=[NSMutableArray new];
 HvReplayCommand*a=command(1),*b=command(2);C([q reserve:4]);[q enqueue:a];C([q reserve:4]);[q enqueue:b];
 HvReplayReadiness(^pre)(HvReplayCommand*)=^HvReplayReadiness(HvReplayCommand*p){return p==a&&!ready?HvReplayPark:HvReplayReady;};
 void(^execute)(HvReplayCommand*)=^(HvReplayCommand*p){writes++;uint32_t x;[p->command getBytes:&x length:4];[stamps addObject:@(x)];};
 void(^barrier)(HvReplayCommand*)=^(HvReplayCommand*p){(void)p;};
 [q pump:pre execute:execute barrier:barrier];C(writes==0);C(stamps.count==0);C(q->entries.count==2);C(atomic_load(&q->reserved)==8);
 for(int i=0;i<20;i++)[q pump:pre execute:execute barrier:barrier];C(writes==0);C(q->entries.firstObject==a);
 ready=YES;[q pump:pre execute:execute barrier:barrier];C(writes==2);C([stamps isEqual:@[@1,@2]]);C(!q->entries.count);C(!atomic_load(&q->reserved));
 [q pump:pre execute:execute barrier:barrier];C(writes==2);
 int callbacks[2]={0};HvReplayCommand*mark=[HvReplayCommand new];mark->barrier=done;mark->opaque=callbacks;[q enqueue:mark];C([q reserve:4]);[q enqueue:command(3)];
 __block HvReplayCommand *held=nil;[q pump:pre execute:execute barrier:^(HvReplayCommand*p){held=p;}];C(q->waiting);C(writes==2);C(callbacks[0]==0);
 [q pump:pre execute:execute barrier:barrier];C(writes==2);
 [q->entries removeObjectAtIndex:0];q->waiting=NO;held->barrier(held->opaque,0);[q pump:pre execute:execute barrier:barrier];C(callbacks[0]==1);C(writes==3);C([stamps isEqual:@[@1,@2,@3]]);
 C([q reserve:32ull<<20]);C(![q reserve:1]);atomic_fetch_sub(&q->reserved,32ull<<20);
 C([q reserve:4]);[q enqueue:command(4)];HvReplayCommand*m2=[HvReplayCommand new];m2->barrier=done;m2->opaque=callbacks;[q enqueue:m2];
 [q pump:^HvReplayReadiness(HvReplayCommand*p){(void)p;return HvReplayFault;}execute:execute barrier:barrier];C(q->faulted);C(writes==3);C(callbacks[1]==1);C(q->entries.count==1);C(atomic_load(&q->reserved)==4);
 [q stop];C(!q->entries.count);C(!atomic_load(&q->reserved));[q stop];C(callbacks[1]==1);C(writes==3);
 HvReplayCommand*m3=[HvReplayCommand new];m3->barrier=done;m3->opaque=callbacks;[q enqueue:m3];C(callbacks[1]==2);
 HvOrderedReplay *late=[HvOrderedReplay new];C([late reserve:4]);[late enqueue:command(9)];
 [late pump:^HvReplayReadiness(HvReplayCommand*p){(void)p;return HvReplayReady;}
     execute:^(HvReplayCommand*p){(void)p;late->faulted=YES;}barrier:barrier];
 C(late->entries.count==1);C(atomic_load(&late->reserved)==4);C(late->faulted);[late stop];C(!atomic_load(&late->reserved));
 printf("%u FIFO preservation/barrier/backpressure/cancellation checks passed\n",checks);return 0;
}}
