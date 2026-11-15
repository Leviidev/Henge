#pragma once
#include "metal4_runtime.h"
#include "metal4_pipeline.h"
#include "metal4_variant.h"
#include "gpu_record_support.h"
#include "gpu_pass_options.h"
#include <math.h>

@interface HvMetal4Plan : NSObject
@property(nonatomic,strong) NSMutableData *options;
@property(nonatomic) BOOL graphics;
@end
@implementation HvMetal4Plan
@end
static inline HvMetal4Plan *hv_metal4_plan_commands(NSArray<NSData *> *commands,HvGpuReject *why) {
    if(!commands.count){hv_gpu_reject(why,HV_GPU_EMPTY,0,0,0,0,0);return nil;}
    NSMutableData *options=[NSMutableData data];NSInteger active=-1;BOOL graphics=NO;
    for(NSData *command in commands) {
        HvGpuSegment s;if(!hv_gpu_segment(command.bytes,command.length,&s,why))return nil;
        if(s.type>2&&s.type!=4){hv_gpu_reject(why,HV_GPU_ENCODER,s.type,0,0,0,0);return nil;}
        if(!s.continuation)active=-1;
        size_t at=s.start;HvGpuRecord r;int status;
        while((status=hv_gpu_next(&s,&at,&r,why))>0) {
            if(!hv_metal4_tag_supported(s.type,r.tag)){hv_gpu_reject(why,HV_GPU_TAG,s.type,r.tag,r.offset,0,r.size);return nil;}
            if(!hv_metal4_payload_supported(s.type,r.tag,r.bytes,r.size)){hv_gpu_reject(why,HV_GPU_PAYLOAD,s.type,r.tag,r.offset,0,r.size);return nil;}
            if(s.type<=2)graphics=YES;
            if(s.type==0&&r.tag==26) {
                HvGpuPassOptions empty={0};active=(NSInteger)(options.length/sizeof empty);
                [options appendBytes:&empty length:sizeof empty];
            } else if(s.type==0&&active>=0&&(r.tag==103||r.tag==106||r.tag==121)) {
                HvGpuPassOptions *p=options.mutableBytes;
                hv_gpu_pass_option(&p[active],r.tag,r.bytes,r.size);
            }
        }
        if(status<0)return nil;
        /* Info segments follow the legacy decoder's CPU-side continuation
           rule and do not by themselves close an existing encoder. */
        if(s.type<=2&&!s.more)active=-1;
    }
    HvMetal4Plan *plan=[HvMetal4Plan new];plan.options=options;plan.graphics=graphics;return plan;
}

@interface HvMetal4Run : NSObject {
@public NSMutableArray<NSData *> *commands;HvMetal4Plan *plan;HvGpuReject rejection;
}
@end
@implementation HvMetal4Run
@end
static inline void hv_metal4_append_run(NSMutableArray<HvMetal4Run *> *runs,NSArray<NSData *> *unit) {
    HvGpuReject why={0};HvMetal4Plan *plan=hv_metal4_plan_commands(unit,&why);
    HvMetal4Run *last=runs.lastObject;
    /* Adjacent units on one backend share a job. A single unsupported encoder
       cannot divert unrelated encoders, and continuations never split. */
    if(last&&((last->plan!=nil)==(plan!=nil))) {
        [last->commands addObjectsFromArray:unit];
        if(plan) {
            /* Planning owns this mutable buffer until replay starts. Append
               once instead of recopying every earlier pass for each unit. */
            [last->plan.options appendData:plan.options];last->plan.graphics=last->plan.graphics||plan.graphics;
        }
    } else {
        HvMetal4Run *run=[HvMetal4Run new];run->commands=[unit mutableCopy];run->plan=plan;run->rejection=why;
        [runs addObject:run];
    }
}
static inline NSArray<HvMetal4Run *> *hv_metal4_command_runs(NSArray<NSData *> *commands) {
    NSMutableArray<HvMetal4Run *> *runs=[NSMutableArray new];NSMutableArray<NSData *> *unit=[NSMutableArray new];
    for(NSData *command in commands) {
        HvGpuSegment s;BOOL parsed=hv_gpu_segment(command.bytes,command.length,&s,NULL);
        if(parsed&&!s.continuation&&unit.count){hv_metal4_append_run(runs,unit);[unit removeAllObjects];}
        [unit addObject:command];
        if(parsed&&s.type<=2&&!s.more){hv_metal4_append_run(runs,unit);[unit removeAllObjects];}
    }
    if(unit.count)hv_metal4_append_run(runs,unit);
    return runs;
}

/* Adapter for representable guest commands. Unsupported features reject the
 * entire uncommitted job; replay then executes every original record on the
 * classic path. Never mix encoders or silently omit a guest operation. */
API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvMetal4Encoder : NSObject {
@public
    id encoder;
    HvMetal4Runtime *runtime;
    HvMetal4Job *job;
    BOOL render;
    BOOL ended;
    HvMetal4Arguments *vertex,*fragment;
    MTLGPUAddress bases[2][31];
    NSUInteger lengths[2][31];
    NSUInteger strides[31];
    HvGpuPassOptions expectedOptions,seenOptions;
}
- (void)endEncoding;
- (void)abortEncoding;
@end

@implementation HvMetal4Encoder
- (BOOL)conformsToProtocol:(Protocol *)protocol {
    if(protocol==@protocol(MTLRenderCommandEncoder))return render;
    if(protocol==@protocol(MTLComputeCommandEncoder))return !render;
    return [super conformsToProtocol:protocol];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector]?:[encoder methodSignatureForSelector:selector];
}
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector]||[encoder respondsToSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)call {
    if(![encoder respondsToSelector:call.selector]){[self doesNotRecognizeSelector:call.selector];return;}
    for(NSUInteger i=2;i<call.methodSignature.numberOfArguments;i++) {
        const char *type=[call.methodSignature getArgumentTypeAtIndex:i];
        if(type[0]=='@'){__unsafe_unretained id resource=nil;[call getArgument:&resource atIndex:i];[runtime retainResource:resource job:job];}
    }
    [call invokeWithTarget:encoder];
}
- (void)endEncoding {
    if(ended)return;
    BOOL valid=!render||hv_gpu_pass_options_equal(&expectedOptions,&seenOptions);
    [self abortEncoding];
    if(!valid)[NSException raise:@"HengeMetal4Fallback" format:@"render store-option plan changed"];
}
- (void)abortEncoding {
    if(ended)return;ended=YES;
    [(id<MTL4CommandEncoder>)encoder barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:(MTL4VisibilityOptionDevice|MTL4VisibilityOptionResourceAlias)];
    [encoder endEncoding];
}
- (void)setRenderPipelineState:(id)state {
    id p=hv_metal4_variant(runtime,state);
    if(!p)hv_metal4_pipeline_fallback(state);
    [runtime retainResource:p job:job];[encoder setRenderPipelineState:p];
}
- (void)setComputePipelineState:(id)state {
    id p=hv_metal4_variant(runtime,state);
    if(!p)hv_metal4_pipeline_fallback(state);
    [runtime retainResource:p job:job];[encoder setComputePipelineState:p];
}
- (void)buffers:(id<MTLBuffer>const __unsafe_unretained *)buffers offsets:(const NSUInteger *)offsets strides:(const NSUInteger *)step range:(NSRange)range stage:(NSUInteger)stage {
    if(range.location>31||range.length>31-range.location)[NSException raise:@"HengeMetal4Fallback" format:@"buffer range"];
    HvMetal4Arguments * table=stage?fragment:vertex;
    for(NSUInteger i=0;i<range.length;i++) {
        id<MTLBuffer> b=buffers[i];NSUInteger slot=range.location+i;
        if(b && offsets[i]>b.length)[NSException raise:@"HengeMetal4Fallback" format:@"buffer offset"];
        [runtime retainResource:b job:job];bases[stage][slot]=b.gpuAddress;lengths[stage][slot]=b.length;
        if(step)strides[slot]=step[i];
        if(step)[table setAddress:b?b.gpuAddress+offsets[i]:0 attributeStride:step[i] atIndex:slot];
        else [table setAddress:b?b.gpuAddress+offsets[i]:0 atIndex:slot];
    }
}
- (void)setVertexBuffers:(id<MTLBuffer>const __unsafe_unretained *)b offsets:(const NSUInteger *)o withRange:(NSRange)r {[self buffers:b offsets:o strides:NULL range:r stage:0];}
- (void)setFragmentBuffers:(id<MTLBuffer>const __unsafe_unretained *)b offsets:(const NSUInteger *)o withRange:(NSRange)r {[self buffers:b offsets:o strides:NULL range:r stage:1];}
- (void)setBuffers:(id<MTLBuffer>const __unsafe_unretained *)b offsets:(const NSUInteger *)o withRange:(NSRange)r {[self buffers:b offsets:o strides:NULL range:r stage:0];}
- (void)setVertexBuffers:(id<MTLBuffer>const __unsafe_unretained *)b offsets:(const NSUInteger *)o attributeStrides:(const NSUInteger *)s withRange:(NSRange)r {[self buffers:b offsets:o strides:s range:r stage:0];}
- (void)offset:(NSUInteger)offset index:(NSUInteger)i stage:(NSUInteger)stage stride:(NSUInteger)stride {
    if(i>=31||!bases[stage][i]||offset>lengths[stage][i])[NSException raise:@"HengeMetal4Fallback" format:@"offset without buffer"];
    HvMetal4Arguments * t=stage?fragment:vertex;
    if(stride!=NSUIntegerMax){strides[i]=stride;[t setAddress:bases[stage][i]+offset attributeStride:stride atIndex:i];}
    else [t setAddress:bases[stage][i]+offset atIndex:i];
}
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:0 stride:NSUIntegerMax];}
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:1 stride:NSUIntegerMax];}
- (void)setBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i {[self offset:o index:i stage:0 stride:NSUIntegerMax];}
- (void)setVertexBufferOffset:(NSUInteger)o attributeStride:(NSUInteger)s atIndex:(NSUInteger)i {[self offset:o index:i stage:0 stride:s];}
- (void)textures:(id<MTLTexture>const __unsafe_unretained *)textures range:(NSRange)range stage:(NSUInteger)stage {
    if(range.location>128||range.length>128-range.location)[NSException raise:@"HengeMetal4Fallback" format:@"texture range"];
    HvMetal4Arguments * t=stage?fragment:vertex;
    for(NSUInteger i=0;i<range.length;i++){id<MTLTexture>x=textures[i];[runtime retainResource:x job:job];[t setTexture:x.gpuResourceID atIndex:range.location+i];}
}
- (void)setVertexTextures:(id<MTLTexture>const __unsafe_unretained *)t withRange:(NSRange)r {[self textures:t range:r stage:0];}
- (void)setFragmentTextures:(id<MTLTexture>const __unsafe_unretained *)t withRange:(NSRange)r {[self textures:t range:r stage:1];}
- (void)setTextures:(id<MTLTexture>const __unsafe_unretained *)t withRange:(NSRange)r {[self textures:t range:r stage:0];}
- (void)samplers:(id<MTLSamplerState>const __unsafe_unretained *)samplers range:(NSRange)range stage:(NSUInteger)stage {
    if(range.location>16||range.length>16-range.location)[NSException raise:@"HengeMetal4Fallback" format:@"sampler range"];
    HvMetal4Arguments * t=stage?fragment:vertex;
    for(NSUInteger i=0;i<range.length;i++){
        id<MTLSamplerState> s=samplers[i],variant=objc_getAssociatedObject(s,"henge.metal4.sampler");
        if(s&&!variant)[NSException raise:@"HengeMetal4Fallback" format:@"sampler descriptor unavailable"];
        [runtime retainResource:variant job:job];[t setSamplerState:variant.gpuResourceID atIndex:range.location+i];
    }
}
- (void)setVertexSamplerStates:(id<MTLSamplerState>const __unsafe_unretained *)s withRange:(NSRange)r {[self samplers:s range:r stage:0];}
- (void)setFragmentSamplerStates:(id<MTLSamplerState>const __unsafe_unretained *)s withRange:(NSRange)r {[self samplers:s range:r stage:1];}
- (void)setSamplerStates:(id<MTLSamplerState>const __unsafe_unretained *)s withRange:(NSRange)r {[self samplers:s range:r stage:0];}
- (void)useHeaps:(id<MTLHeap>const __unsafe_unretained *)h count:(NSUInteger)n {for(NSUInteger i=0;i<n;i++)[runtime retainResource:h[i] job:job];}
- (void)useHeaps:(id<MTLHeap>const __unsafe_unretained *)h count:(NSUInteger)n stages:(MTLRenderStages)s {(void)s;[self useHeaps:h count:n];}
- (void)useResources:(id<MTLResource>const __unsafe_unretained *)r count:(NSUInteger)n usage:(MTLResourceUsage)u {(void)u;for(NSUInteger i=0;i<n;i++)[runtime retainResource:r[i] job:job];}
- (void)useResources:(id<MTLResource>const __unsafe_unretained *)r count:(NSUInteger)n usage:(MTLResourceUsage)u stages:(MTLRenderStages)s {(void)s;[self useResources:r count:n usage:u];}
/* A Metal fence remains real on the classic queue: pre-existing waits run in
   the bridge head; updates publish in its tail. An update before a wait in this
   job is satisfied by full Metal4 barriers and never waits for its own tail. */
- (void)updateFence:(id<MTLFence>)f {
    if(!f)return;[job->fenceUpdates addObject:f];[runtime retainResource:f job:job];
    [(id<MTL4CommandEncoder>)encoder barrierAfterEncoderStages:MTLStageAll beforeEncoderStages:MTLStageAll visibilityOptions:(MTL4VisibilityOptionDevice|MTL4VisibilityOptionResourceAlias)];
}
- (void)waitForFence:(id<MTLFence>)f {
    if(!f)return;if(![job->fenceUpdates containsObject:f])[job->fenceWaits addObject:f];[runtime retainResource:f job:job];
    [(id<MTL4CommandEncoder>)encoder barrierAfterEncoderStages:MTLStageAll beforeEncoderStages:MTLStageAll visibilityOptions:(MTL4VisibilityOptionDevice|MTL4VisibilityOptionResourceAlias)];
}
- (void)updateFence:(id<MTLFence>)f afterStages:(MTLRenderStages)stages {(void)stages;[self updateFence:f];}
- (void)waitForFence:(id<MTLFence>)f beforeStages:(MTLRenderStages)stages {(void)stages;[self waitForFence:f];}
- (void)clampedSamplers:(id<MTLSamplerState>const __unsafe_unretained *)samplers minimums:(const float *)minimums maximums:(const float *)maximums range:(NSRange)range stage:(NSUInteger)stage {
    if(range.location>16||range.length>16-range.location)[NSException raise:@"HengeMetal4Fallback" format:@"sampler range"];
    HvMetal4Arguments * t=stage?fragment:vertex;
    for(NSUInteger i=0;i<range.length;i++){
        id<MTLSamplerState> sampler=samplers[i];MTLResourceID zero={0};
        if(!sampler){[t setSamplerState:zero atIndex:range.location+i];continue;}
        MTLSamplerDescriptor *base=objc_getAssociatedObject(sampler,"henge.metal4.sampler.descriptor");
        if(!base||!isfinite(minimums[i])||!isfinite(maximums[i])||minimums[i]<0||maximums[i]<minimums[i])
            [NSException raise:@"HengeMetal4Fallback" format:@"sampler clamp unavailable"];
        uint32_t bits[2];memcpy(&bits[0],&minimums[i],4);memcpy(&bits[1],&maximums[i],4);
        NSData *key=[NSData dataWithBytes:bits length:sizeof bits];
        NSMutableDictionary *cache=objc_getAssociatedObject(sampler,"henge.metal4.sampler.clamps");
        if(!cache){cache=[NSMutableDictionary new];objc_setAssociatedObject(sampler,"henge.metal4.sampler.clamps",cache,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
        id<MTLSamplerState> variant=cache[key];
        if(!variant){
            MTLSamplerDescriptor *d=[base copy];d.supportArgumentBuffers=YES;d.lodMinClamp=minimums[i];d.lodMaxClamp=maximums[i];
            variant=[sampler.device newSamplerStateWithDescriptor:d];
            if(!variant)[NSException raise:@"HengeMetal4Fallback" format:@"sampler clamp refused"];
            if(cache.count>=16)[cache removeAllObjects];cache[key]=variant;
        }
        [runtime retainResource:variant job:job];[t setSamplerState:variant.gpuResourceID atIndex:range.location+i];
    }
}
- (void)setVertexSamplerStates:(id<MTLSamplerState>const __unsafe_unretained *)s lodMinClamps:(const float *)a lodMaxClamps:(const float *)b withRange:(NSRange)r {[self clampedSamplers:s minimums:a maximums:b range:r stage:0];}
- (void)setFragmentSamplerStates:(id<MTLSamplerState>const __unsafe_unretained *)s lodMinClamps:(const float *)a lodMaxClamps:(const float *)b withRange:(NSRange)r {[self clampedSamplers:s minimums:a maximums:b range:r stage:1];}
- (void)memoryBarrierWithScope:(MTLBarrierScope)s {(void)s;[(id<MTL4CommandEncoder>)encoder barrierAfterEncoderStages:MTLStageAll beforeEncoderStages:MTLStageAll visibilityOptions:(MTL4VisibilityOptionDevice|MTL4VisibilityOptionResourceAlias)];}
- (void)setViewport:(MTLViewport)v {[(id<MTL4RenderCommandEncoder>)encoder setViewport:v];}
- (void)setScissorRect:(MTLScissorRect)v {[(id<MTL4RenderCommandEncoder>)encoder setScissorRect:v];}
- (void)setCullMode:(MTLCullMode)v {[(id<MTL4RenderCommandEncoder>)encoder setCullMode:v];}
- (void)setDepthClipMode:(MTLDepthClipMode)v {[(id<MTL4RenderCommandEncoder>)encoder setDepthClipMode:v];}
- (void)setFrontFacingWinding:(MTLWinding)v {[(id<MTL4RenderCommandEncoder>)encoder setFrontFacingWinding:v];}
- (void)setTriangleFillMode:(MTLTriangleFillMode)v {[(id<MTL4RenderCommandEncoder>)encoder setTriangleFillMode:v];}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)state {[runtime retainResource:state job:job];[(id<MTL4RenderCommandEncoder>)encoder setDepthStencilState:state];}
- (void)setScissorRects:(const MTLScissorRect *)rects count:(NSUInteger)n {[(id<MTL4RenderCommandEncoder>)encoder setScissorRects:rects count:n];}
- (void)setViewports:(const MTLViewport *)views count:(NSUInteger)n {[(id<MTL4RenderCommandEncoder>)encoder setViewports:views count:n];}
- (void)setDepthBias:(float)a slopeScale:(float)b clamp:(float)c {[(id<MTL4RenderCommandEncoder>)encoder setDepthBias:a slopeScale:b clamp:c];}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {[(id<MTL4RenderCommandEncoder>)encoder setBlendColorRed:r green:g blue:b alpha:a];}
- (void)setStencilFrontReferenceValue:(uint32_t)a backReferenceValue:(uint32_t)b {[(id<MTL4RenderCommandEncoder>)encoder setStencilFrontReferenceValue:a backReferenceValue:b];}
- (void)setColorStoreAction:(MTLStoreAction)a atIndex:(NSUInteger)i {[(id<MTL4RenderCommandEncoder>)encoder setColorStoreAction:a atIndex:i];}
- (void)setDepthStoreAction:(MTLStoreAction)a {[(id<MTL4RenderCommandEncoder>)encoder setDepthStoreAction:a];}
- (void)setStencilStoreAction:(MTLStoreAction)a {[(id<MTL4RenderCommandEncoder>)encoder setStencilStoreAction:a];}
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)value atIndex:(NSUInteger)index {
    if(index>=8||((uint64_t)value&~UINT64_C(1)))
        [NSException raise:@"HengeMetal4Fallback" format:@"color store options"];
    seenOptions.values[index]=value;seenOptions.mask|=(uint16_t)(1u<<index);
}
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)value {
    if((uint64_t)value&~UINT64_C(1))[NSException raise:@"HengeMetal4Fallback" format:@"depth store options"];
    seenOptions.values[8]=value;seenOptions.mask|=1u<<8;
}
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)value {
    if((uint64_t)value&~UINT64_C(1))[NSException raise:@"HengeMetal4Fallback" format:@"stencil store options"];
    seenOptions.values[9]=value;seenOptions.mask|=1u<<9;
}
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n {[(id<MTL4RenderCommandEncoder>)encoder drawPrimitives:p vertexStart:s vertexCount:n];}
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)c {[(id<MTL4RenderCommandEncoder>)encoder drawPrimitives:p vertexStart:s vertexCount:n instanceCount:c];}
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n instanceCount:(NSUInteger)c baseInstance:(NSUInteger)i {[(id<MTL4RenderCommandEncoder>)encoder drawPrimitives:p vertexStart:s vertexCount:n instanceCount:c baseInstance:i];}
- (void)dispatchThreads:(MTLSize)n threadsPerThreadgroup:(MTLSize)g {[(id<MTL4ComputeCommandEncoder>)encoder dispatchThreads:n threadsPerThreadgroup:g];}
- (void)dispatchThreadgroups:(MTLSize)n threadsPerThreadgroup:(MTLSize)g {[(id<MTL4ComputeCommandEncoder>)encoder dispatchThreadgroups:n threadsPerThreadgroup:g];}
- (void)setThreadgroupMemoryLength:(NSUInteger)n atIndex:(NSUInteger)i {[(id<MTL4ComputeCommandEncoder>)encoder setThreadgroupMemoryLength:n atIndex:i];}
- (void)setImageblockWidth:(NSUInteger)w height:(NSUInteger)h {[(id<MTL4ComputeCommandEncoder>)encoder setImageblockWidth:w height:h];}
- (void)fillBuffer:(id<MTLBuffer>)b range:(NSRange)r value:(uint8_t)v {[runtime retainResource:b job:job];[(id<MTL4ComputeCommandEncoder>)encoder fillBuffer:b range:r value:v];}
- (void)generateMipmapsForTexture:(id<MTLTexture>)texture {
    [runtime retainResource:texture job:job];[(id<MTL4ComputeCommandEncoder>)encoder generateMipmapsForTexture:texture];
}
- (void)copyFromBuffer:(id<MTLBuffer>)a sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)b destinationOffset:(NSUInteger)to size:(NSUInteger)n {
 [runtime retainResource:a job:job];[runtime retainResource:b job:job];[(id<MTL4ComputeCommandEncoder>)encoder copyFromBuffer:a sourceOffset:so toBuffer:b destinationOffset:to size:n];
}
- (void)copyFromBuffer:(id<MTLBuffer>)a sourceOffset:(NSUInteger)o sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)image sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)b destinationSlice:(NSUInteger)s destinationLevel:(NSUInteger)l destinationOrigin:(MTLOrigin)origin options:(MTLBlitOption)options {
 [runtime retainResource:a job:job];[runtime retainResource:b job:job];[(id<MTL4ComputeCommandEncoder>)encoder copyFromBuffer:a sourceOffset:o sourceBytesPerRow:row sourceBytesPerImage:image sourceSize:size toTexture:b destinationSlice:s destinationLevel:l destinationOrigin:origin options:options];
}
- (void)copyFromTexture:(id<MTLTexture>)a sourceSlice:(NSUInteger)s sourceLevel:(NSUInteger)l sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)b destinationOffset:(NSUInteger)o destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)image options:(MTLBlitOption)options {
 [runtime retainResource:a job:job];[runtime retainResource:b job:job];[(id<MTL4ComputeCommandEncoder>)encoder copyFromTexture:a sourceSlice:s sourceLevel:l sourceOrigin:origin sourceSize:size toBuffer:b destinationOffset:o destinationBytesPerRow:row destinationBytesPerImage:image options:options];
}
- (void)copyFromTexture:(id<MTLTexture>)a sourceSlice:(NSUInteger)s sourceLevel:(NSUInteger)l sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)b destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dest {
 [runtime retainResource:a job:job];[runtime retainResource:b job:job];[(id<MTL4ComputeCommandEncoder>)encoder copyFromTexture:a sourceSlice:s sourceLevel:l sourceOrigin:origin sourceSize:size toTexture:b destinationSlice:ds destinationLevel:dl destinationOrigin:dest];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)c baseVertex:(NSInteger)v baseInstance:(NSUInteger)i {
    NSUInteger unit=t==MTLIndexTypeUInt16?2:4;
    if(o>b.length||o%unit||n>(b.length-o)/unit)[NSException raise:@"HengeMetal4Fallback" format:@"index bounds"];
    [runtime retainResource:b job:job];
    [encoder drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:b.gpuAddress+o indexBufferLength:((b.length-o)/unit)*unit instanceCount:c baseVertex:v baseInstance:i];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o {[self drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:b indexBufferOffset:o instanceCount:1 baseVertex:0 baseInstance:0];}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)b indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)c {[self drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:b indexBufferOffset:o instanceCount:c baseVertex:0 baseInstance:0];}
- (void)drawPrimitives:(MTLPrimitiveType)primitive indirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:(NSUInteger)offset {
    if(offset%4||offset>buffer.length||sizeof(MTLDrawPrimitivesIndirectArguments)>buffer.length-offset)
        [NSException raise:@"HengeMetal4Fallback" format:@"indirect draw bounds"];
    [runtime retainResource:buffer job:job];
    [(id<MTL4RenderCommandEncoder>)encoder drawPrimitives:primitive indirectBuffer:buffer.gpuAddress+offset];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitive indexType:(MTLIndexType)type indexBuffer:(id<MTLBuffer>)index indexBufferOffset:(NSUInteger)indexOffset indirectBuffer:(id<MTLBuffer>)indirect indirectBufferOffset:(NSUInteger)offset {
    NSUInteger unit=type==MTLIndexTypeUInt16?2:4;
    if(indexOffset%unit||indexOffset>index.length||offset%4||offset>indirect.length||sizeof(MTLDrawIndexedPrimitivesIndirectArguments)>indirect.length-offset)
        [NSException raise:@"HengeMetal4Fallback" format:@"indexed indirect draw bounds"];
    [runtime retainResource:index job:job];[runtime retainResource:indirect job:job];
    [(id<MTL4RenderCommandEncoder>)encoder drawIndexedPrimitives:primitive indexType:type indexBuffer:index.gpuAddress+indexOffset indexBufferLength:((index.length-indexOffset)/unit)*unit indirectBuffer:indirect.gpuAddress+offset];
}
@end

static HvMetal4Encoder *hv_metal4_encoder(HvMetal4Runtime *runtime,HvMetal4Job *job,id encoder,BOOL render) API_AVAILABLE(macos(26.0),ios(26.0));
static HvMetal4Encoder *hv_metal4_encoder(HvMetal4Runtime *runtime,HvMetal4Job *job,id encoder,BOOL render) {
    if(!encoder)return nil;
    HvMetal4Encoder *p=[HvMetal4Encoder new];p->runtime=runtime;p->job=job;p->encoder=encoder;p->render=render;
    p->vertex=[runtime table:job];if(render)p->fragment=[runtime table:job];
    if(!p->vertex || (render&&!p->fragment)){[encoder endEncoding];return nil;}
    [(id<MTL4CommandEncoder>)encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:(MTL4VisibilityOptionDevice|MTL4VisibilityOptionResourceAlias)];
    if(render){[encoder setArgumentTable:p->vertex.table atStages:MTLRenderStageVertex];[encoder setArgumentTable:p->fragment.table atStages:MTLRenderStageFragment];}
    else [encoder setArgumentTable:p->vertex.table];
    return p;
}

API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvMetal4Buffer : NSObject {
@public HvMetal4Runtime *runtime;HvMetal4Job *job;NSData *passOptions;NSUInteger passIndex;
}
@end
@implementation HvMetal4Buffer
- (id)computeCommandEncoder {return hv_metal4_encoder(runtime,job,[job->buffer computeCommandEncoder],NO);}
- (id)blitCommandEncoder {return hv_metal4_encoder(runtime,job,[job->buffer computeCommandEncoder],NO);}
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)old {
    if(passIndex>=passOptions.length/sizeof(HvGpuPassOptions))
        [NSException raise:@"HengeMetal4Fallback" format:@"render pass missing option plan"];
    HvGpuPassOptions options=((const HvGpuPassOptions *)passOptions.bytes)[passIndex++];
    for(NSUInteger i=0;i<8;i++)if(options.mask&(1u<<i))old.colorAttachments[i].storeActionOptions=(MTLStoreActionOptions)options.values[i];
    if(options.mask&(1u<<8))old.depthAttachment.storeActionOptions=(MTLStoreActionOptions)options.values[8];
    if(options.mask&(1u<<9))old.stencilAttachment.storeActionOptions=(MTLStoreActionOptions)options.values[9];
    MTL4RenderPassDescriptor *d=[MTL4RenderPassDescriptor new];
    for(NSUInteger i=0;i<8;i++){
        d.colorAttachments[i]=old.colorAttachments[i];
        [runtime retainResource:old.colorAttachments[i].texture job:job];
        [runtime retainResource:old.colorAttachments[i].resolveTexture job:job];
    }
    d.depthAttachment=old.depthAttachment;d.stencilAttachment=old.stencilAttachment;
    id attachments[]={old.depthAttachment.texture,old.depthAttachment.resolveTexture,old.stencilAttachment.texture,old.stencilAttachment.resolveTexture};
    for(unsigned i=0;i<4;i++)[runtime retainResource:attachments[i] job:job];
    d.visibilityResultBuffer=old.visibilityResultBuffer;[runtime retainResource:old.visibilityResultBuffer job:job];
    d.renderTargetArrayLength=old.renderTargetArrayLength;d.renderTargetWidth=old.renderTargetWidth;d.renderTargetHeight=old.renderTargetHeight;
    d.defaultRasterSampleCount=old.defaultRasterSampleCount;d.imageblockSampleLength=old.imageblockSampleLength;
    d.threadgroupMemoryLength=old.threadgroupMemoryLength;d.tileWidth=old.tileWidth;d.tileHeight=old.tileHeight;
    HvMetal4Encoder *result=hv_metal4_encoder(runtime,job,[job->buffer renderCommandEncoderWithDescriptor:d],YES);
    if(result)result->expectedOptions=options;
    return result;
}
@end
