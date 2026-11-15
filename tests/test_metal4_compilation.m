#import <Foundation/Foundation.h>
#include <assert.h>
#include <unistd.h>
#include <pthread.h>
#include "../devices/metal4_encoder.h"

@interface WarmFunction : NSObject @end
@implementation WarmFunction
- (MTLPatchType)patchType {return MTLPatchTypeNone;}
@end
@interface WarmSource : NSProxy {
@public id descriptor,function;
}
@end
@implementation WarmSource
- (id)vertexFunction {return function;}
- (id)computeFunction {return function;}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {return [descriptor methodSignatureForSelector:s];}
- (void)forwardInvocation:(NSInvocation *)call {[call invokeWithTarget:descriptor];}
@end
@interface WarmState : NSObject
@property NSUInteger width;
@end
@implementation WarmState
- (NSUInteger)threadExecutionWidth {return _width;}
- (NSUInteger)maxTotalThreadsPerThreadgroup {return 128;}
- (NSUInteger)staticThreadgroupMemoryLength {return 0;}
@end
@interface WarmRuntime : HvMetal4Runtime {
@public
    dispatch_semaphore_t started,releaseCompiler;
    _Atomic unsigned calls;
    _Atomic bool fail,throwError,badABI;
}
@end
@implementation WarmRuntime
- (instancetype)init {
    if(!(self=[super init]))return nil;
    pipelineQueue=[HvMetal4CompileQueue new];
    started=dispatch_semaphore_create(0);releaseCompiler=dispatch_semaphore_create(0);return self;
}
- (id)pipeline:(id)d tag:(uint32_t)t bundle:(HvPipelineBundle *)b {
    assert(d&&(t==11||t==14));(void)b;
    atomic_fetch_add(&calls,1);dispatch_semaphore_signal(started);
    assert(!dispatch_semaphore_wait(releaseCompiler,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    if(atomic_load(&throwError))[NSException raise:@"InjectedCompilerFailure" format:@"test"];
    if(atomic_load(&fail))return nil;
    WarmState *s=[WarmState new];s.width=atomic_load(&badABI)?16:32;return s;
}
@end
static WarmState *source(unsigned tag) {
    WarmState *state=[WarmState new];state.width=32;
    WarmSource *s=[WarmSource alloc];s->descriptor=tag==11?[MTLComputePipelineDescriptor new]:[MTLRenderPipelineDescriptor new];
    s->function=[WarmFunction new];
    MTL4LibraryFunctionDescriptor *f=[MTL4LibraryFunctionDescriptor new];f.name=@"recorded_function";
    objc_setAssociatedObject(s->function,"henge.metal4.function",f,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(state,"henge.metal4.source",@{@"tag":@(tag),@"descriptor":s},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return state;
}
static void waitStarted(WarmRuntime *r) {assert(!dispatch_semaphore_wait(r->started,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));}
static void finish(WarmRuntime *r,HvMetal4Variant *v) {
    dispatch_semaphore_signal(r->releaseCompiler);
    assert(!dispatch_group_wait(v->finished,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
}
static void barrier(HvMetal4CompileQueue *q) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    assert([q enqueue:^(BOOL allowed){assert(allowed);dispatch_semaphore_signal(done);}]);
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
}
/* pthread_create publishes the captured objects explicitly to TSan. Keeping
   them in this joined context also avoids dispatch_apply's copied ObjC-block
   capture publication being invisible to some libdispatch/TSan combinations. */
typedef struct {
    __unsafe_unretained WarmRuntime *runtime;
    __unsafe_unretained WarmState *state;
    __unsafe_unretained dispatch_semaphore_t start;
} WarmConcurrentContext;
static void *prepareConcurrent(void *opaque) {@autoreleasepool{
    WarmConcurrentContext *context=opaque;
    assert(!dispatch_semaphore_wait(context->start,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    for(unsigned i=0;i<8;i++)assert(!hv_metal4_variant(context->runtime,context->state));
    return NULL;
}}
int main(void){@autoreleasepool{
    alarm(30);
    WarmRuntime *runtime=[WarmRuntime new];
    WarmState *a=source(14),*b=source(14),*c=source(14);
    HvMetal4Variant *av=hv_metal4_prepare(runtime,a);waitStarted(runtime);
    /* Every request returns while the recording compiler is still blocked.
       No sleep, timing threshold or substituted implementation is involved. */
    for(unsigned i=0;i<1000;i++)assert(!hv_metal4_variant(runtime,a));
    assert(atomic_load(&runtime->calls)==1);
    @try{hv_metal4_pipeline_fallback(a);assert(0);}@catch(NSException *e){assert([e.name isEqual:@"HengeMetal4Warming"]);}
    HvMetal4Variant *bv=hv_metal4_prepare(runtime,b),*cv=hv_metal4_prepare(runtime,c);
    assert(atomic_load(&bv->phase)==HV_M4_PIPELINE_QUEUED);
    assert(atomic_load(&cv->phase)==HV_M4_PIPELINE_IDLE);
    assert(atomic_load(&runtime->pipelineQueue->admitted)==2);
    [runtime->pipelineQueue setEnabled:NO];finish(runtime,av);
    assert(!dispatch_group_wait(bv->finished,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    assert(atomic_load(&av->phase)==HV_M4_PIPELINE_READY&&hv_metal4_variant(runtime,a));
    assert(atomic_load(&bv->phase)==HV_M4_PIPELINE_IDLE&&!hv_metal4_variant(runtime,b));
    assert(atomic_load(&runtime->pipelineQueue->cancelled)==1);
    [runtime->pipelineQueue setEnabled:YES];
    assert(hv_metal4_prepare(runtime,b)==bv);waitStarted(runtime);finish(runtime,bv);barrier(runtime->pipelineQueue);
    assert(hv_metal4_variant(runtime,b)&&atomic_load(&runtime->calls)==2);
    /* Concurrent first use is coalesced to one retained compiler request. */
    unsigned before=atomic_load(&runtime->calls);
    dispatch_semaphore_t start=dispatch_semaphore_create(0);
    WarmConcurrentContext context={runtime,c,start};pthread_t workers[8];
    for(unsigned i=0;i<8;i++)assert(!pthread_create(&workers[i],NULL,prepareConcurrent,&context));
    for(unsigned i=0;i<8;i++)dispatch_semaphore_signal(start);
    for(unsigned i=0;i<8;i++)assert(!pthread_join(workers[i],NULL));
    waitStarted(runtime);assert(atomic_load(&runtime->calls)==before+1);
    finish(runtime,cv);barrier(runtime->pipelineQueue);assert(hv_metal4_variant(runtime,c));
    for(unsigned mode=0;mode<3;mode++) {
        atomic_store(&runtime->fail,mode==0);atomic_store(&runtime->throwError,mode==1);atomic_store(&runtime->badABI,mode==2);
        WarmState *bad=source(mode==2?11:14);HvMetal4Variant *v=hv_metal4_prepare(runtime,bad);
        waitStarted(runtime);finish(runtime,v);barrier(runtime->pipelineQueue);
        assert(atomic_load(&v->phase)==HV_M4_PIPELINE_REJECTED&&!hv_metal4_variant(runtime,bad));
        before=atomic_load(&runtime->calls);
        for(unsigned i=0;i<100;i++)assert(!hv_metal4_variant(runtime,bad));
        assert(before==atomic_load(&runtime->calls));
        @try{hv_metal4_pipeline_fallback(bad);assert(0);}@catch(NSException *e){assert([e.name isEqual:@"HengeMetal4Fallback"]);}
    }
    atomic_store(&runtime->fail,false);atomic_store(&runtime->throwError,false);atomic_store(&runtime->badABI,false);
    __weak WarmState *weakState;
    HvMetal4Variant *held;
    @autoreleasepool{
        WarmState *retiring=source(11);weakState=retiring;
        held=hv_metal4_prepare(runtime,retiring);waitStarted(runtime);retiring=nil;
        assert(weakState); /* old compute state remains alive for ABI checks */
    }
    finish(runtime,held);barrier(runtime->pipelineQueue);
    assert(!weakState&&atomic_load(&held->phase)==HV_M4_PIPELINE_READY);
    before=atomic_load(&runtime->calls);
    HvMetal4Variant *missing=hv_metal4_prepare(runtime,[WarmState new]);
    assert(atomic_load(&missing->phase)==HV_M4_PIPELINE_REJECTED&&before==atomic_load(&runtime->calls));
    [runtime->pipelineQueue setSuspended:YES];[runtime->pipelineQueue setEnabled:YES];
    WarmState *paused=source(14);HvMetal4Variant *pv=hv_metal4_prepare(runtime,paused);
    assert(atomic_load(&pv->phase)==HV_M4_PIPELINE_IDLE);
    [runtime->pipelineQueue setEnabled:NO];[runtime->pipelineQueue setSuspended:NO];
    assert(!hv_metal4_variant(runtime,paused)&&atomic_load(&pv->phase)==HV_M4_PIPELINE_IDLE);
    [runtime->pipelineQueue setEnabled:YES];hv_metal4_prepare(runtime,paused);
    waitStarted(runtime);finish(runtime,pv);barrier(runtime->pipelineQueue);
    assert(hv_metal4_variant(runtime,paused));
    puts("PASS Metal4 pipeline warmup: render caller never waits for blocked compilation; two-request bound, concurrent coalescing, pressure cancellation/readmission, retained ABI state, compiler errors and immutable ready/rejected reuse");
    return 0;
}}
