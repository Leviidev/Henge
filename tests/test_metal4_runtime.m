#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <unistd.h>
#include "../devices/metal4_encoder.h"
int main(int argc,const char **argv){@autoreleasepool{
    (void)argc;(void)argv;alarm(60);NSApplicationLoad();
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device){NSArray *all=MTLCopyAllDevices();if(all.count==1)device=all[0];}
    HvMetal4Runtime *runtime=[[HvMetal4Runtime alloc]initWithDevice:device];
    if(!runtime){fprintf(stderr,"METAL4_UNAVAILABLE device=%s; actual execution not validated\n",device.name.UTF8String?:"none");return 78;}
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;kernel void bump(device uint *v [[buffer(0)]],uint i [[thread_position_in_grid]]){v[i]+=7;}\n";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLFunction> function=[library newFunctionWithName:@"bump"];
    hv_metal4_note_function(function,library);
    MTLComputePipelineDescriptor *descriptor=[MTLComputePipelineDescriptor new];descriptor.computeFunction=function;
    id state=[device newComputePipelineStateWithDescriptor:descriptor options:0 reflection:nil error:&error];
    if(!state){fprintf(stderr,"pipeline error %s\n",error.description.UTF8String);return 1;}
    objc_setAssociatedObject(state,"henge.metal4.source",@{@"tag":@11,@"descriptor":descriptor},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* The real guest keeps using its classic PSO while this optional variant
       warms. This direct Metal4 readback test waits for that same compiler
       completion event before constructing its explicit Metal4-only job. */
    HvMetal4Variant *ready=hv_metal4_prepare(runtime,state);
    if(dispatch_group_wait(ready->finished,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))||!hv_metal4_variant(runtime,state))return 7;
    id<MTLCommandQueue> classic=[device newCommandQueue];os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;
    id<MTLBuffer> values=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    memset(values.contents,0,256);
    for(unsigned round=0;round<20;round++){
        id<MTLCommandBuffer> upload=[classic commandBuffer];id<MTLBlitCommandEncoder> fill=[upload blitCommandEncoder];
        [fill fillBuffer:values range:NSMakeRange(0,256) value:(uint8_t)round];[fill endEncoding];
        os_unfair_lock_lock(&lock);[upload commit];os_unfair_lock_unlock(&lock);
        HvMetal4Job *job=[runtime begin];if(!job)return 2;
        HvMetal4Buffer *bridge=[HvMetal4Buffer new];bridge->runtime=runtime;bridge->job=job;
        id e=[bridge computeCommandEncoder];[e setComputePipelineState:state];
        id<MTLBuffer> args[]={values};NSUInteger offsets[]={0};[e setBuffers:args offsets:offsets withRange:NSMakeRange(0,1)];
        [e dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(16,1,1)];[e endEncoding];
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL ok=NO;
        BOOL accepted=[runtime commit:job classicQueue:classic lock:&lock drawable:nil completion:^(BOOL good){ok=good;dispatch_semaphore_signal(done);}];
        if(!accepted || dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)) || !ok)return 3;
        id<MTLBuffer> readback=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> check=[classic commandBuffer];id<MTLBlitCommandEncoder> back=[check blitCommandEncoder];
        [back copyFromBuffer:values sourceOffset:0 toBuffer:readback destinationOffset:0 size:256];[back endEncoding];
        os_unfair_lock_lock(&lock);[check commit];os_unfair_lock_unlock(&lock);[check waitUntilCompleted];
        if(check.status!=MTLCommandBufferStatusCompleted)return 6;
        for(unsigned i=0;i<64;i++)if(((uint32_t *)readback.contents)[i]!=round*0x01010101u+7)return 4;
    }
    HvMetal4Job *discard=[runtime begin];[runtime discard:discard];
    if(atomic_load(&runtime->submitted)!=20 || atomic_load(&runtime->failed))return 5;
    puts("PASS actual Metal4 compute: GPU readback, 20 allocator/table reuse cycles, explicit residency and classic/Metal4 ordering");return 0;
}}
