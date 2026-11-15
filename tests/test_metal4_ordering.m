/* Executes the real submission/pool/fence code with recording queues. It proves
 * ordering and lifetime on CI without claiming Metal4 GPU execution. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <unistd.h>
static NSMutableArray<NSString *> *trace;
@interface HvTestOptions : MTL4CommitOptions
@property(nonatomic,strong) NSMutableArray *handlers;
@end
@implementation HvTestOptions
- (void)addFeedbackHandler:(MTL4CommitFeedbackHandler)handler {
    if(!_handlers)_handlers=[NSMutableArray new];[_handlers addObject:[handler copy]];
}
@end
#define MTL4CommitOptions HvTestOptions
#include "../devices/metal4_encoder.h"
#undef MTL4CommitOptions
@interface RecordingObject : NSObject
@property(nonatomic,copy) NSString *name;
@property(nonatomic,strong) NSError *error;
@property(nonatomic) uint64_t signaledValue;
@property(nonatomic) CFTimeInterval GPUStartTime,GPUEndTime;
@end
@implementation RecordingObject
- (void)reset {[trace addObject:@"allocator.reset"];}
- (void)beginCommandBufferWithAllocator:(id)a {(void)a;[trace addObject:@"metal4.begin"];}
- (void)endCommandBuffer {[trace addObject:@"metal4.end"];}
- (void)useResidencySet:(id)r {(void)r;[trace addObject:@"metal4.resident"];}
- (void)addAllocation:(id)a {(void)a;}
- (void)removeAllAllocations {}
- (void)commit {[trace addObject:(_name?:@"residency.commit")];}
- (void)waitForFence:(id)f {(void)f;[trace addObject:@"fence.wait"];}
- (void)updateFence:(id)f {(void)f;[trace addObject:@"fence.update"];}
- (void)endEncoding {}
- (void)barrierAfterEncoderStages:(MTLStages)a beforeEncoderStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)c {(void)a;(void)b;(void)c;[trace addObject:@"metal4.barrier"];}
- (void)encodeSignalEvent:(id)e value:(uint64_t)v {(void)e;(void)v;[trace addObject:@"classic.signal.encode"];}
- (void)encodeWaitForEvent:(id)e value:(uint64_t)v {(void)e;(void)v;[trace addObject:@"classic.wait.encode"];}
@end
@interface RecordingBuffer : RecordingObject
@property(nonatomic) BOOL noEncoder;
@end
@implementation RecordingBuffer
- (id)computeCommandEncoder {return _noEncoder?nil:[RecordingObject new];}
@end
@interface RecordingQueue : NSObject
@property(nonatomic) BOOL synchronous,errorFeedback;
@property(nonatomic) NSUInteger allocations,nilAt,nilEncoderAt;
@property(nonatomic,strong) HvTestOptions *pending;
@end
@implementation RecordingQueue
- (id)commandBuffer {
    _allocations++;if(_nilAt==_allocations)return nil;
    RecordingBuffer *b=[RecordingBuffer new];b.name=_allocations%2?@"classic.head.commit":@"classic.tail.commit";
    b.noEncoder=_nilEncoderAt==_allocations;return b;
}
- (void)waitForEvent:(id)e value:(uint64_t)v {(void)e;(void)v;[trace addObject:@"metal4.wait"];}
- (void)signalEvent:(id)e value:(uint64_t)v {(void)e;(void)v;[trace addObject:@"metal4.signal"];}
- (void)finish {
    RecordingObject *f=[RecordingObject new];f.GPUStartTime=1;f.GPUEndTime=1.002;
    if(_errorFeedback)f.error=[NSError errorWithDomain:@"test" code:1 userInfo:nil];
    HvTestOptions *pending=_pending;_pending=nil;
    for(MTL4CommitFeedbackHandler handler in pending.handlers)handler((id)f);
}
- (void)commit:(id const *)buffers count:(NSUInteger)count options:(HvTestOptions *)options {
    assert(count==1&&buffers[0]);[trace addObject:@"metal4.commit"];_pending=options;
    if(_synchronous)[self finish];
}
@end
@interface RecordingDevice : NSObject
@property(nonatomic,strong) RecordingQueue *queue;
@property(nonatomic,strong) RecordingObject *event;
@end
@implementation RecordingDevice
- (instancetype)init {if((self=[super init])){_queue=[RecordingQueue new];_event=[RecordingObject new];_event.name=@"testgpu";}return self;}
- (BOOL)supportsFamily:(MTLGPUFamily)f {(void)f;return YES;}
- (id)architecture {return _event;}
- (id)newMTL4CommandQueueWithDescriptor:(id)d error:(NSError **)e {(void)d;(void)e;return _queue;}
- (id)newPipelineDataSetSerializerWithDescriptor:(id)d {(void)d;return nil;}
- (id)newCompilerWithDescriptor:(id)d error:(NSError **)e {(void)d;(void)e;return [NSObject new];}
- (id)newSharedEvent {return _event;}
- (id)newCommandAllocator {return [RecordingObject new];}
- (id)newCommandBuffer {return [RecordingObject new];}
- (id)newResidencySetWithDescriptor:(id)d error:(NSError **)e {(void)d;(void)e;return [RecordingObject new];}
@end
@interface CacheCapture : NSObject
@property(nonatomic,strong) NSMutableSet *keys;
@property(nonatomic,strong) dispatch_semaphore_t started,releaseWrite;
@end
@implementation CacheCapture
- (BOOL)serializeAsArchiveAndFlushToURL:(NSURL *)url error:(NSError **)error {
    (void)error;if(_started){dispatch_semaphore_signal(_started);dispatch_semaphore_wait(_releaseWrite,DISPATCH_TIME_FOREVER);}
    NSMutableData *data=[[NSJSONSerialization dataWithJSONObject:_keys.allObjects options:0 error:nil]mutableCopy];
    while(data.length<512){uint8_t space=' ';[data appendBytes:&space length:1];}
    return [data writeToURL:url atomically:YES];
}
@end
@interface CacheCompiler : NSObject
@property(nonatomic,strong) CacheCapture *capture;
@property(nonatomic,strong) dispatch_semaphore_t started,releaseCompile;
@property(nonatomic) BOOL throwError;
@end
@implementation CacheCompiler
- (id)newRenderPipelineStateWithDescriptor:(id)d compilerTaskOptions:(id)o error:(NSError **)e {
    if(_started){dispatch_semaphore_signal(_started);assert(!dispatch_semaphore_wait(_releaseCompile,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));}
    if(_throwError)[NSException raise:@"InjectedCompilerFailure" format:@"test"];
    (void)o;(void)e;[_capture.keys addObject:d];return [NSObject new];
}
@end
@interface CacheArchive : NSObject
@property(nonatomic,strong) NSArray *keys;
@end
@implementation CacheArchive
- (id)newRenderPipelineStateWithDescriptor:(id)d error:(NSError **)e {(void)e;return [_keys containsObject:d]?[NSObject new]:nil;}
@end
@interface CacheDevice : RecordingDevice
@property(nonatomic,strong) CacheCapture *capture;
@property(nonatomic) unsigned compilers;
@end
@implementation CacheDevice
- (id)newPipelineDataSetSerializerWithDescriptor:(id)d {
    (void)d;_capture=[CacheCapture new];_capture.keys=[NSMutableSet new];return _capture;
}
- (id)newCompilerWithDescriptor:(MTL4CompilerDescriptor *)d error:(NSError **)e {
    (void)e;_compilers++;CacheCompiler *c=[CacheCompiler new];c.capture=(id)d.pipelineDataSetSerializer;return c;
}
- (id)newArchiveWithURL:(NSURL *)url error:(NSError **)e {
    (void)e;NSArray *keys=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:nil];
    if(![keys isKindOfClass:NSArray.class])return nil;CacheArchive *a=[CacheArchive new];a.keys=keys;return a;
}
@end
static void testCache(void){
    NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSURL *directory=[root URLByAppendingPathComponent:@"current"];
    CacheDevice *device=[CacheDevice new];HvMetal4Runtime *runtime=[[HvMetal4Runtime alloc]initWithDevice:(id)device];assert(runtime);
    [runtime setValue:directory forKey:@"cacheDirectory"];
    assert([runtime pipeline:@"first" tag:0xe bundle:nil]);
    CacheCapture *old=device.capture;old.started=dispatch_semaphore_create(0);old.releaseWrite=dispatch_semaphore_create(0);
    dispatch_group_t saved=dispatch_group_create();dispatch_group_async(saved,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{[runtime flushPipelines];});
    assert(!dispatch_semaphore_wait(old.started,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
    dispatch_semaphore_t compiled=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{assert([runtime pipeline:@"next epoch" tag:0xe bundle:nil]);dispatch_semaphore_signal(compiled);});
    assert(!dispatch_semaphore_wait(compiled,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
    assert(device.capture!=old&&device.compilers>=2);
    dispatch_semaphore_signal(old.releaseWrite);assert(!dispatch_group_wait(saved,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)));
    uint64_t misses=atomic_load(&runtime->pipeline_cache_misses);assert([runtime pipeline:@"first" tag:0xe bundle:nil]);
    assert(atomic_load(&runtime->pipeline_cache_hits)==1&&atomic_load(&runtime->pipeline_cache_misses)==misses);
    assert(atomic_load(&runtime->pipeline_cache_writes)==1);
    [runtime setArchiveAdmission:NO];assert([runtime pipeline:@"uncached under pressure" tag:0xe bundle:nil]);
    [runtime setArchiveAdmission:YES];assert([runtime pipeline:@"first" tag:0xe bundle:nil]);
    assert(atomic_load(&runtime->pipeline_cache_hits)==2);
    /* Production budget updates must return while a compiler holds the lock.
       Finish the request only after the nonblocking pressure call returns. */
    CacheCompiler *held=(id)runtime.compiler;
    held.started=dispatch_semaphore_create(0);held.releaseCompile=dispatch_semaphore_create(0);
    dispatch_group_t compiling=dispatch_group_create();
    dispatch_group_async(compiling,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{assert([runtime pipeline:@"blocked compile" tag:0xe bundle:nil]);});
    assert(!dispatch_semaphore_wait(held.started,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    HvPipelineBundle *screenBundle=[HvPipelineBundle new];CacheArchive *screenArchive=[CacheArchive new];
    screenArchive.keys=@[@"screen bundle"];screenBundle->archives=@[(id<MTL4Archive>)screenArchive];
    assert([runtime pipeline:@"screen bundle" tag:0xe bundle:screenBundle]&&screenBundle->hits==1);
    [runtime setArchiveAdmission:NO];
    dispatch_semaphore_signal(held.releaseCompile);
    assert(!dispatch_group_wait(compiling,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    [runtime setArchiveAdmission:YES];assert([runtime pipeline:@"recovered after compile" tag:0xe bundle:nil]);
    /* A framework exception cannot strand the shared compiler mutex. */
    CacheCompiler *throwing=(id)runtime.compiler;throwing.throwError=YES;
    BOOL caught=NO;@try{[runtime pipeline:@"throws" tag:0xe bundle:nil];}@catch(NSException *e){(void)e;caught=YES;}
    assert(caught);throwing.throwError=NO;
    assert([runtime pipeline:@"after exception" tag:0xe bundle:nil]);
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    puts("PASS Metal4 archive epochs: atomic file reuse, memory-pressure recovery, old capture isolated and new pipeline request completes while writer is blocked (recording compiler)");
    puts("PASS Metal4 compiler pressure: render budget update never waits for blocked compiler; latest admission applied on completion; compiler exceptions release mutex");
    puts("PASS Metal4 bundled display: immutable archive hit returns while optional guest compiler is blocked");
}
static void order(NSString *a,NSString *b){assert([trace indexOfObject:a]!=NSNotFound);assert([trace indexOfObject:a]<[trace indexOfObject:b]);}
int main(void){@autoreleasepool{
    alarm(30);trace=[NSMutableArray new];
    testCache();
    for(unsigned mode=0;mode<5;mode++){
        RecordingDevice *device=[RecordingDevice new];device.queue.synchronous=mode==0;
        HvMetal4Runtime *runtime=[[HvMetal4Runtime alloc]initWithDevice:(id)device];assert(runtime);
        RecordingQueue *classic=[RecordingQueue new];
        if(mode==2)classic.nilAt=2;
        if(mode==3)classic.nilEncoderAt=2;
        HvMetal4Job *job=[runtime begin];assert(job);
        HvMetal4Encoder *encoder=[HvMetal4Encoder new];encoder->job=job;encoder->runtime=runtime;encoder->encoder=[RecordingObject new];
        id oldFence=[NSObject new],newFence=[NSObject new];
        [encoder waitForFence:oldFence];[encoder updateFence:newFence];[encoder waitForFence:newFence];
        assert(job->fenceWaits.count==1&&job->fenceUpdates.count==1);
        __weak id weak;@autoreleasepool{id token=[NSObject new];weak=token;[runtime retainResource:token job:job];}
        assert(weak);[trace removeAllObjects];os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;__block unsigned callbacks=0;
        BOOL accepted=[runtime commit:job classicQueue:(id)classic lock:&lock drawable:nil completion:^(BOOL ok){assert(ok!=(mode==4));callbacks++;}];
        if(mode==2||mode==3){assert(!accepted&&!callbacks&&!weak);assert(![trace containsObject:@"metal4.commit"]&&!atomic_load(&runtime->submitted));}
        else{
            assert(accepted);order(@"fence.wait",@"classic.head.commit");order(@"classic.head.commit",@"metal4.wait");order(@"metal4.wait",@"metal4.commit");order(@"metal4.commit",@"metal4.signal");order(@"metal4.signal",@"classic.tail.commit");
            assert([trace containsObject:@"fence.update"]);assert(atomic_load(&runtime->submitted)==1);
            if(mode){assert(!callbacks&&weak);device.queue.errorFeedback=mode==4;[device.queue finish];}
            assert(callbacks==1&&!weak&&atomic_load(&runtime->completed)==1);
            assert(atomic_load(&runtime->gpu_duration_ns)>1900000);
            if(mode==4){assert(atomic_load(&runtime->failed)==1&&device.event.signaledValue>=2);assert(![runtime begin]);continue;}
        }
        HvMetal4Job *again=[runtime begin];assert(again==job);assert(!again->fenceWaits.count&&!again->fenceUpdates.count&&!again->keep.count);[runtime discard:again];
    }
    RecordingDevice *device=[RecordingDevice new];HvMetal4Runtime *runtime=[[HvMetal4Runtime alloc]initWithDevice:(id)device];
    HvMetal4Job *held=[runtime begin];[runtime discard:held];
    [runtime setArchiveAdmission:NO];HvMetal4Job *pressure=[runtime begin];assert(pressure!=held);[runtime discard:pressure];
    [runtime setArchiveAdmission:YES];HvMetal4Job *recovered=[runtime begin];assert(recovered!=pressure);[runtime discard:recovered];
    puts("PASS Metal4 memory pressure: idle resources released, active allocations remain available, normal pooling recovers");
    puts("PASS production Metal4 ordering/pool/fences: synchronous and delayed feedback, rejected bridge allocations, failed GPU event recovery, retained resources, no double completion (recording queues; no GPU execution claim)");return 0;
}}
