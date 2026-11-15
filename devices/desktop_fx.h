#pragma once
#import <MetalFX/MetalFX.h>
#import <Foundation/Foundation.h>

/* One bounded resource pool for the existing presenter. A lease lives through
   GPU completion and any cached image reads, so an in-flight texture/scaler is
   never rebound or overwritten. No CPU readback or additional frame timer. */
API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvDesktopFXFrame : NSObject {
@public
    id<MTL4FXSpatialScaler> scaler;
    id<MTLTexture> input,output;
    NSUInteger width,height,outWidth,outHeight;
    uint64_t epoch;
}
@end
@implementation HvDesktopFXFrame @end
@class HvDesktopFXPool;
API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvDesktopFXLease : NSObject
@property(nonatomic,strong) HvDesktopFXFrame *frame;
@property(nonatomic,weak) HvDesktopFXPool *owner;
@end
API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvDesktopFXPool : NSObject {
    id<MTLDevice> _device;
    id<MTL4Compiler> _compiler;
    NSMutableArray<HvDesktopFXFrame *> *_idle;
    NSUInteger _created,_limit;
    uint64_t _epoch;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (HvDesktopFXLease *)acquireWidth:(NSUInteger)width height:(NSUInteger)height outputWidth:(NSUInteger)ow outputHeight:(NSUInteger)oh NS_RETURNS_RETAINED;
- (void)recycle:(HvDesktopFXFrame *)frame;
- (void)trim;
- (void)setLimit:(NSUInteger)limit;
@end
@implementation HvDesktopFXLease
- (void)dealloc { [_owner recycle:_frame]; }
@end
@implementation HvDesktopFXPool
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if(!(self=[super init]) || ![MTLFXSpatialScalerDescriptor supportsMetal4FX:device])return nil;
    _device=device;_idle=[NSMutableArray new];_limit=3;
    // A private compiler avoids racing the guest archive compiler's epochs.
    _compiler=[device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:nil];
    return _compiler?self:nil;
}
- (void)trim { @synchronized(self) { _epoch++;_created-=_idle.count;[_idle removeAllObjects]; } }
- (void)setLimit:(NSUInteger)limit { @synchronized(self) {
    _limit=MIN(limit,3u);
    while(_created>_limit && _idle.count){[_idle removeLastObject];_created--;}
} }
- (void)recycle:(HvDesktopFXFrame *)frame { @synchronized(self) {
    if(frame->epoch==_epoch && _created<=_limit)[_idle addObject:frame];else _created--;
} }
- (HvDesktopFXLease *)acquireWidth:(NSUInteger)width height:(NSUInteger)height outputWidth:(NSUInteger)ow outputHeight:(NSUInteger)oh {
    if(!width||!height||ow<width||oh<height||ow>8192||oh>8192)return nil;
    @synchronized(self) {
        HvDesktopFXFrame *frame=nil;
        for(HvDesktopFXFrame *candidate in _idle)
            if(candidate->width==width&&candidate->height==height&&candidate->outWidth==ow&&candidate->outHeight==oh){frame=candidate;break;}
        if(frame)[_idle removeObject:frame];
        else {
            // Dispose only idle wrong-size allocations. Three leases cover the
            // cached image plus two admitted presentations, independent of vCPUs.
            _created-=_idle.count;[_idle removeAllObjects];
            if(_created>=_limit)return nil;
            frame=[HvDesktopFXFrame new];
            MTLFXSpatialScalerDescriptor *d=[MTLFXSpatialScalerDescriptor new];
            d.inputWidth=width;d.inputHeight=height;d.outputWidth=ow;d.outputHeight=oh;
            d.colorTextureFormat=d.outputTextureFormat=MTLPixelFormatBGRA8Unorm;
            d.colorProcessingMode=MTLFXSpatialScalerColorProcessingModePerceptual;
            frame->scaler=[d newSpatialScalerWithDevice:_device compiler:_compiler];
            if(!frame->scaler)return nil;
            MTLTextureDescriptor *t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
            t.storageMode=MTLStorageModePrivate;t.usage=frame->scaler.colorTextureUsage|MTLTextureUsageRenderTarget;
            frame->input=[_device newTextureWithDescriptor:t];
            t.width=ow;t.height=oh;t.usage=frame->scaler.outputTextureUsage|MTLTextureUsageShaderRead;
            frame->output=[_device newTextureWithDescriptor:t];
            if(!frame->input||!frame->output)return nil;
            frame->width=width;frame->height=height;frame->outWidth=ow;frame->outHeight=oh;frame->epoch=_epoch;
            frame->scaler.colorTexture=frame->input;frame->scaler.outputTexture=frame->output;
            frame->scaler.inputContentWidth=width;frame->scaler.inputContentHeight=height;
            _created++;
        }
        HvDesktopFXLease *lease=[HvDesktopFXLease new];lease.frame=frame;lease.owner=self;return lease;
    }
}
@end
