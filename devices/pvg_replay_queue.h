/* Worker-confined FIFO; reservation alone is callable by the producer.
 * A parked head is never removed, executed, or acknowledged. */
#import <Foundation/Foundation.h>
#include <stdatomic.h>
typedef NS_ENUM(NSInteger,HvReplayReadiness){HvReplayFault=-1,HvReplayPark=0,HvReplayReady=1};
@interface HvReplayCommand:NSObject {
@public
 NSData *command,*taskView;
 uint32_t channel,task;
 uint64_t generation;
 NSMutableDictionary *reads,*buffers,*requests,*localSources,*localResults;
 NSUInteger snapshotBytes;
 BOOL awaitingLease;
 NSString *error;
 void (*barrier)(void *,int);
 void *opaque;
 void (^completion)(int cancelled);
}
- (BOOL)isBarrier;
- (void)complete:(int)cancelled;
@end
@implementation HvReplayCommand
- (BOOL)isBarrier{return barrier!=NULL||completion!=nil;}
- (void)complete:(int)cancelled{if(barrier)barrier(opaque,cancelled);if(completion)completion(cancelled);}
- (instancetype)init {if((self=[super init])){reads=[NSMutableDictionary new];buffers=[NSMutableDictionary new];requests=[NSMutableDictionary new];localSources=[NSMutableDictionary new];localResults=[NSMutableDictionary new];}return self;}
@end
@interface HvOrderedReplay:NSObject {
@public
 NSMutableArray<HvReplayCommand*> *entries;
 _Atomic uint64_t reserved;
 BOOL stopped,waiting,faulted,pumping;
}
- (BOOL)reserve:(uint64_t)bytes;
- (void)enqueue:(HvReplayCommand*)item;
- (void)stop;
- (void)fail;
- (void)pump:(HvReplayReadiness(^)(HvReplayCommand*))preflight execute:(void(^)(HvReplayCommand*))execute barrier:(void(^)(HvReplayCommand*))barrier;
@end
@implementation HvOrderedReplay
- (instancetype)init {if((self=[super init]))entries=[NSMutableArray new];return self;}
- (BOOL)reserve:(uint64_t)n {
 const uint64_t limit=32ull<<20;if(n>limit)return NO;
 uint64_t old=atomic_load(&reserved);
 do {if(old>limit-n)return NO;}while(!atomic_compare_exchange_weak(&reserved,&old,old+n));return YES;
}
- (void)enqueue:(HvReplayCommand*)item {
 if(stopped){if([item isBarrier])[item complete:1];atomic_fetch_sub(&reserved,item->command.length);return;}
 if(faulted&&[item isBarrier]){[item complete:1];atomic_fetch_sub(&reserved,item->command.length);return;}
 [entries addObject:item];
}
- (void)stop {
 if(stopped)return;stopped=YES;
 for(HvReplayCommand *item in entries){if([item isBarrier])[item complete:1];atomic_fetch_sub(&reserved,item->command.length);}
 [entries removeAllObjects];waiting=NO;
}
- (void)fail {
 faulted=YES;
 for(HvReplayCommand *queued in [entries copy])if([queued isBarrier]){
     [entries removeObject:queued];[queued complete:1];atomic_fetch_sub(&reserved,queued->command.length);
 }
}
- (void)pump:(HvReplayReadiness(^)(HvReplayCommand*))preflight execute:(void(^)(HvReplayCommand*))execute barrier:(void(^)(HvReplayCommand*))barrier {
 if(stopped||waiting||faulted||pumping)return;pumping=YES;
 @try{
  while(entries.count&&!stopped){HvReplayCommand *item=entries.firstObject;
   if([item isBarrier]){waiting=YES;barrier(item);break;}
   HvReplayReadiness state=preflight(item);
   if(state==HvReplayPark)break;
   if(state==HvReplayFault){[self fail];break;}
   execute(item);if(faulted){[self fail];break;}[entries removeObjectAtIndex:0];atomic_fetch_sub(&reserved,item->command.length);
  }
 }@finally{pumping=NO;}
}
@end
