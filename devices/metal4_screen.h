#pragma once
#include "metal4_runtime.h"
#include "pipeline_bundle.h"
#include "desktop_fx.h"

API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvMetal4Screen : NSObject {
    HvMetal4Runtime *_runtime;
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _plain,_linear,_cursor;
    id<MTLSamplerState> _smooth,_sharp;
    HvDesktopFXPool *_fxPool;
    HvDesktopFXLease *_cachedFX,*_pendingFX;
    id<MTLTexture> _cachedSource,_pendingSource;
    uint64_t _cachedEpoch,_pendingEpoch;
    uint32_t _cachedMode,_pendingMode;
    BOOL _fxCacheEnabled,_fxUnavailableLogged,_fxSourceSizeLogged;
    NSUInteger _fxLimit;
@public
    _Atomic uint64_t fx_encoded,fx_reused,fx_fallback;
    _Atomic uint64_t fx_pressure_fallback,fx_resource_fallback,fx_size_fallback;

}
- (instancetype)initWithRuntime:(HvMetal4Runtime *)runtime device:(id<MTLDevice>)device library:(id<MTLLibrary>)library bundle:(HvPipelineBundle *)bundle;
- (HvMetal4Job *)encode:(id<MTLTexture>)source target:(id<MTLTexture>)target half:(BOOL)half mode:(uint32_t)mode
                 cursor:(id<MTLTexture>)cursor rect:(const float *)rect sharp:(BOOL)sharp;
- (HvMetal4Job *)encode:(id<MTLTexture>)source target:(id<MTLTexture>)target half:(BOOL)half mode:(uint32_t)mode
                 cursor:(id<MTLTexture>)cursor rect:(const float *)rect sharp:(BOOL)sharp imageEpoch:(uint64_t)epoch upscale:(BOOL)upscale;
- (void)didCommit:(BOOL)committed;
- (void)setFXCacheAdmission:(BOOL)enabled;
- (void)setFXCacheLimit:(NSUInteger)limit;
@end
@implementation HvMetal4Screen
- (instancetype)initWithRuntime:(HvMetal4Runtime *)runtime device:(id<MTLDevice>)device library:(id<MTLLibrary>)library bundle:(HvPipelineBundle *)bundle {
    if(!(self=[super init]))return nil;_runtime=runtime;_device=device;_fxCacheEnabled=YES;_fxLimit=3;
    id<MTLRenderPipelineState> states[3];
    NSArray *names=@[@"screen_plain",@"screen_linear",@"screen_cursor"];
    for(unsigned i=0;i<3;i++){
        MTL4RenderPipelineDescriptor *d=[MTL4RenderPipelineDescriptor new];
        d.vertexFunctionDescriptor=hv_metal4_function(library,@"screen_v");
        d.fragmentFunctionDescriptor=hv_metal4_function(library,names[i]);
        d.rasterSampleCount=1;d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
        if(i==2){
            MTL4RenderPipelineColorAttachmentDescriptor *c=d.colorAttachments[0];c.blendingState=MTL4BlendStateEnabled;
            c.sourceRGBBlendFactor=c.sourceAlphaBlendFactor=MTLBlendFactorOne;
            c.destinationRGBBlendFactor=c.destinationAlphaBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
        }
        states[i]=[runtime pipeline:d tag:0xe bundle:bundle];
        if(!states[i])return nil;
    }
    _plain=states[0];_linear=states[1];_cursor=states[2];
    MTLSamplerDescriptor *sampler=[MTLSamplerDescriptor new];sampler.supportArgumentBuffers=YES;
    sampler.minFilter=sampler.magFilter=MTLSamplerMinMagFilterLinear;
    _smooth=[device newSamplerStateWithDescriptor:sampler];sampler.minFilter=sampler.magFilter=MTLSamplerMinMagFilterNearest;
    _sharp=[device newSamplerStateWithDescriptor:sampler];if(!_smooth||!_sharp)return nil;
    return self;
}
- (BOOL)draw:(id<MTLTexture>)source target:(id<MTLTexture>)target half:(BOOL)half cursor:(id<MTLTexture>)cursor rect:(const float *)rect sharp:(BOOL)sharp
         job:(HvMetal4Job *)job vertex:(HvMetal4Arguments *)vertex fragment:(HvMetal4Arguments *)fragment {
    MTL4RenderPassDescriptor *pass=[MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> e=[job->buffer renderCommandEncoderWithDescriptor:pass];
    if(!e)return NO;
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:(MTL4VisibilityOptionDevice|MTL4VisibilityOptionResourceAlias)];
    [vertex setAddress:job->uniforms.gpuAddress atIndex:0];[fragment setAddress:job->uniforms.gpuAddress+16 atIndex:0];
    [fragment setTexture:source.gpuResourceID atIndex:0];[fragment setSamplerState:_smooth.gpuResourceID atIndex:0];
    [e setArgumentTable:vertex.table atStages:MTLRenderStageVertex];[e setArgumentTable:fragment.table atStages:MTLRenderStageFragment];
    [e setRenderPipelineState:half?_linear:_plain];[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    if(cursor&&rect){
        [vertex setAddress:job->uniforms.gpuAddress+32 atIndex:0];[fragment setTexture:cursor.gpuResourceID atIndex:0];
        [fragment setSamplerState:(sharp?_sharp:_smooth).gpuResourceID atIndex:0];
        [e setRenderPipelineState:_cursor];[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:(MTL4VisibilityOptionDevice|MTL4VisibilityOptionResourceAlias)];[e endEncoding];
    return YES;
}
- (void)setFXCacheAdmission:(BOOL)enabled {
    [self setFXCacheLimit:enabled?3:0];
}
- (void)setFXCacheLimit:(NSUInteger)limit {
    limit=MIN(limit,3u);
    // The presenter reapplies current admission for every damaged frame.
    // Trim only on a transition, not once per fallback presentation.
    if(_fxLimit==limit)return;
    BOOL enabled=limit!=0;
    _fxLimit=limit;
    _fxCacheEnabled=enabled;
    [_fxPool setLimit:limit];
    if(!enabled){_cachedFX=nil;_cachedSource=nil;[_fxPool trim];}
    // A failed compiler/pool allocation must not permanently disable FX.
    // Retry once after real pressure recovery, without retrying every frame.
    else if(!_fxPool)_fxUnavailableLogged=NO;
}
- (void)didCommit:(BOOL)committed {
    // Called on the presenter immediately after enqueue/discard, before the next
    // encode. Queue ordering makes a queued cached output safe for subsequent
    // reads; an unsubmitted image can never become the cached desktop.
    if(committed && _pendingFX && _fxCacheEnabled){
        _cachedFX=_pendingFX;_cachedSource=_pendingSource;_cachedEpoch=_pendingEpoch;_cachedMode=_pendingMode;
    }
    _pendingFX=nil;_pendingSource=nil;
}
- (HvMetal4Job *)encode:(id<MTLTexture>)source target:(id<MTLTexture>)target half:(BOOL)half mode:(uint32_t)mode cursor:(id<MTLTexture>)cursor rect:(const float *)rect sharp:(BOOL)sharp {
    return [self encode:source target:target half:half mode:mode cursor:cursor rect:rect sharp:sharp imageEpoch:0 upscale:NO];
}
- (HvMetal4Job *)encode:(id<MTLTexture>)source target:(id<MTLTexture>)target half:(BOOL)half mode:(uint32_t)mode cursor:(id<MTLTexture>)cursor rect:(const float *)rect sharp:(BOOL)sharp imageEpoch:(uint64_t)epoch upscale:(BOOL)upscale {
    [self didCommit:NO];
    if(!source||!target)return nil;
    HvMetal4Job *job=[_runtime begin];if(!job)return nil;
    if(!job->uniforms)job->uniforms=[_device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    HvMetal4Arguments *vertex=[_runtime table:job],*fragment=[_runtime table:job];
    if(!job->uniforms||!vertex||!fragment){[_runtime discard:job];return nil;}
    float full[]={-1,-1,2,2};memcpy(job->uniforms.contents,full,sizeof full);
    memcpy((uint8_t *)job->uniforms.contents+16,&mode,sizeof mode);
    if(rect)memcpy((uint8_t *)job->uniforms.contents+32,rect,16);
    for(id resource in @[source,target,job->uniforms,_plain,_linear,_cursor,_smooth,_sharp])[_runtime retainResource:resource job:job];
    if(cursor)[_runtime retainResource:cursor job:job];
    BOOL wantsFX=upscale && source.width<target.width && source.height<target.height;
    if(wantsFX && _fxCacheEnabled){
        uint32_t key=mode | (half?0x80000000u:0);
        HvDesktopFXLease *lease=_cachedFX;
        BOOL reuse=epoch && lease && _cachedEpoch==epoch && _cachedSource==source && _cachedMode==key &&
            lease.frame->outWidth==target.width && lease.frame->outHeight==target.height;
        if(!reuse){
            if(!_fxPool && !_fxUnavailableLogged){
                _fxPool=[[HvDesktopFXPool alloc]initWithDevice:_device];
                [_fxPool setLimit:_fxLimit];
            }
            lease=[_fxPool acquireWidth:source.width height:source.height outputWidth:target.width outputHeight:target.height];
        }
        if(lease){
            HvDesktopFXFrame *frame=lease.frame;
            for(id resource in @[lease,frame->input,frame->output,frame->scaler])[_runtime retainResource:resource job:job];
            if(!reuse){
                // Normalize the existing half-float/encoded colour policy at the
                // LOW input size. No full-size downsample or CPU pixel copy.
                if(![self draw:source target:frame->input half:half cursor:nil rect:NULL sharp:NO job:job vertex:vertex fragment:fragment]){
                    [_runtime discard:job];return nil;
                }
                [frame->scaler encodeToCommandBuffer:job->buffer];
                if(atomic_fetch_add(&fx_encoded,1)==0)fprintf(stderr,"hengevm: desktop-metalfx: active=1 input=%lux%lu output=%lux%lu mode=Metal4-spatial/perceptual cursor=post-upscale native-detail=reconstructed\n",(unsigned long)source.width,(unsigned long)source.height,(unsigned long)target.width,(unsigned long)target.height);
            }else atomic_fetch_add(&fx_reused,1);
            _pendingFX=lease;_pendingSource=source;_pendingEpoch=epoch;_pendingMode=key;
            source=frame->output;half=NO;
        }else{
            atomic_fetch_add(&fx_fallback,1);
            atomic_fetch_add(&fx_resource_fallback,1);
            if(!_fxUnavailableLogged){_fxUnavailableLogged=YES;fprintf(stderr,"hengevm: desktop-metalfx: active=0 reason=capability-or-resource-admission fallback=existing-linear-compositor\n");}
        }
    }else if(wantsFX){
        atomic_fetch_add(&fx_fallback,1);
        atomic_fetch_add(&fx_pressure_fallback,1);
    }
    if(upscale && !wantsFX){
        atomic_fetch_add(&fx_fallback,1);
        atomic_fetch_add(&fx_size_fallback,1);
        if(!_fxSourceSizeLogged){_fxSourceSizeLogged=YES;fprintf(stderr,"hengevm: desktop-metalfx: active=0 reason=input-not-smaller input=%lux%lu output=%lux%lu; choose macOS Displays default to reduce backing pixels\n",(unsigned long)source.width,(unsigned long)source.height,(unsigned long)target.width,(unsigned long)target.height);}
    }
    if(![self draw:source target:target half:half cursor:cursor rect:rect sharp:sharp job:job vertex:vertex fragment:fragment]){
        [self didCommit:NO];[_runtime discard:job];return nil;
    }
    return job;
}
@end
