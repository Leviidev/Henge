#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <time.h>
#include <unistd.h>
#include "../devices/gpu_binding_cache.h"
static double clockNow(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
int main(void){@autoreleasepool{
    alarm(60);NSApplicationLoad();id<MTLDevice> d=MTLCreateSystemDefaultDevice();
    if(!d){NSArray *all=MTLCopyAllDevices();if(all.count==1)d=all[0];}
    if(!d){fputs("No GPU for binding benchmark\n",stderr);return 78;}
    NSError *error=nil;id<MTLLibrary> lib=[d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;kernel void run(device uint *v [[buffer(0)]]){v[0]+=7;}" options:nil error:&error];
    id<MTLComputePipelineState> p=[d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"run"] error:&error];assert(p);
    id<MTLCommandQueue> q=[d newCommandQueue];id<MTLBuffer> b=[d newBufferWithLength:512 options:MTLResourceStorageModeShared];assert(q&&b);
    for(unsigned round=0;round<4;round++)for(unsigned order=0;order<2;order++){@autoreleasepool{
        unsigned enabled=(round+order)%2;HvBindingCache cache={.disabled=!enabled};
        id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];[e setComputePipelineState:p];
        memset(b.contents,0,b.length);double begin=clockNow();
        for(unsigned i=0;i<100000;i++){
            NSUInteger offset=((i/64)&1)*256;uintptr_t key[]={0x201,(uintptr_t)(__bridge void *)b,offset};
            if(hv_binding_update(&cache,HV_BIND_VERTEX_BUFFER,key,sizeof key)){id<MTLBuffer> buffers[]={b};[e setBuffers:buffers offsets:&offset withRange:NSMakeRange(0,1)];}
        }
        double ms=(clockNow()-begin)*1000;
        [e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];
        assert(cb.status==MTLCommandBufferStatusCompleted);assert(((uint32_t *)b.contents)[0]==7&&((uint32_t *)b.contents)[64]==0);
        assert(enabled?cache.skipped>98000:cache.skipped==0);
        printf("GPU_BINDING_ENCODING enabled=%u round=%u setters=100000 skipped=%llu cpu_ms=%.3f device=%s\n",enabled,round,(unsigned long long)cache.skipped,ms,d.name.UTF8String);
    }}
    puts("PASS real classic Metal GPU results with repeated/range-changing bindings, both cache modes; encoding benchmark excludes commit/wait and is not a game FPS measurement");return 0;
}}
