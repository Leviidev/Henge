/* Executes the production pool and compositor against recording objects. This
   proves routing/lifetime/cache behavior, NOT MetalFX image quality or GPU time. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <assert.h>
static NSMutableArray<NSString *> *events;
static BOOL supported=YES,failTextures=NO,failCompiler=NO;
static NSUInteger compilerCreations;
@interface FXTexture : NSObject
@property NSUInteger width,height;
@property MTLPixelFormat pixelFormat;
@property MTLTextureUsage usage;
@end
@implementation FXTexture
- (MTLResourceID)gpuResourceID { return (MTLResourceID){(uint64_t)(__bridge void *)self}; }
@end
@interface FXScaler : NSObject
@property(nonatomic,strong) id colorTexture,outputTexture;
@property NSUInteger inputContentWidth,inputContentHeight;
@end
@implementation FXScaler
- (MTLTextureUsage)colorTextureUsage {return MTLTextureUsageShaderRead;}
- (MTLTextureUsage)outputTextureUsage {return MTLTextureUsageShaderWrite;}
- (void)encodeToCommandBuffer:(id)buffer {
    (void)buffer;assert(self.colorTexture && self.outputTexture);
    [events addObject:@"FX"];
}
@end
@interface FXDescriptor : NSObject
@property NSUInteger inputWidth,inputHeight,outputWidth,outputHeight;
@property MTLPixelFormat colorTextureFormat,outputTextureFormat;
@property MTLFXSpatialScalerColorProcessingMode colorProcessingMode;
@end
@implementation FXDescriptor
+ (BOOL)supportsMetal4FX:(id)device {(void)device;return supported;}
- (id)newSpatialScalerWithDevice:(id)device compiler:(id)compiler {
    (void)device;assert(compiler);assert(self.colorProcessingMode==MTLFXSpatialScalerColorProcessingModePerceptual);
    assert(self.colorTextureFormat==MTLPixelFormatBGRA8Unorm && self.outputTextureFormat==MTLPixelFormatBGRA8Unorm);
    return [FXScaler new];
}
@end
#define MTLFXSpatialScalerDescriptor FXDescriptor
#include "../devices/metal4_screen.h"
#undef MTLFXSpatialScalerDescriptor
@interface FXUniforms : NSObject { uint8_t bytes[256]; }
@end
@implementation FXUniforms
- (void *)contents {return bytes;}
- (MTLGPUAddress)gpuAddress {return 0x10000;}
@end
@interface FXSampler : NSObject @end
@implementation FXSampler
- (MTLResourceID)gpuResourceID {return (MTLResourceID){5};}
@end
@interface FXDevice : NSObject @end
@implementation FXDevice
- (id)newCompilerWithDescriptor:(id)d error:(NSError **)error {(void)d;(void)error;compilerCreations++;return failCompiler?nil:[NSObject new];}
- (id)newTextureWithDescriptor:(MTLTextureDescriptor *)d {
    if(failTextures)return nil;
    assert(d.storageMode==MTLStorageModePrivate);
    FXTexture *t=[FXTexture new];t.width=d.width;t.height=d.height;t.usage=d.usage;t.pixelFormat=d.pixelFormat;return t;
}
- (id)newSamplerStateWithDescriptor:(id)d {(void)d;return [FXSampler new];}
- (id)newBufferWithLength:(NSUInteger)n options:(MTLResourceOptions)o {(void)o;assert(n==256);return [FXUniforms new];}
@end
@interface FXTable : NSObject @end
@implementation FXTable
- (void)setAddress:(MTLGPUAddress)a atIndex:(NSUInteger)i {(void)a;(void)i;}
- (void)setAddress:(MTLGPUAddress)a attributeStride:(NSUInteger)s atIndex:(NSUInteger)i {(void)a;(void)s;(void)i;}
- (void)setTexture:(MTLResourceID)a atIndex:(NSUInteger)i {(void)a;(void)i;}
- (void)setSamplerState:(MTLResourceID)a atIndex:(NSUInteger)i {(void)a;(void)i;}
@end
@interface FXEncoder : NSObject @end
@implementation FXEncoder
- (void)barrierAfterQueueStages:(MTLStages)a beforeStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)c {(void)a;(void)b;(void)c;}
- (void)barrierAfterStages:(MTLStages)a beforeQueueStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)c {(void)a;(void)b;(void)c;}
- (void)setArgumentTable:(id)t atStages:(MTLRenderStages)s {assert([t isKindOfClass:FXTable.class]);(void)s;}
- (void)setRenderPipelineState:(id)p {(void)p;}
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)c {(void)t;(void)s;assert(c==4);[events addObject:@"draw"];}
- (void)endEncoding {[events addObject:@"end"];}
@end
@interface FXBuffer : NSObject @end
@implementation FXBuffer
- (id)renderCommandEncoderWithDescriptor:(MTL4RenderPassDescriptor *)d {assert(d.colorAttachments[0].texture);[events addObject:@"render"];return [FXEncoder new];}
@end
@interface FXRuntime : NSObject @end
@implementation FXRuntime
- (id)pipeline:(id)d tag:(uint32_t)tag bundle:(id)b {(void)d;(void)b;assert(tag==0xe);return [NSObject new];}
- (HvMetal4Job *)begin {HvMetal4Job *j=[HvMetal4Job new];j->buffer=(id)[FXBuffer new];j->keep=[NSMutableSet new];return j;}
- (id)table:(id)job {(void)job;return [[HvMetal4Arguments alloc]initWithTable:(id)[FXTable new]];}
- (void)retainResource:(id)r job:(HvMetal4Job *)j {[j->keep addObject:r];}
- (void)discard:(HvMetal4Job *)j {[j->keep removeAllObjects];}
@end
static FXTexture *texture(NSUInteger w,NSUInteger h){FXTexture *t=[FXTexture new];t.width=w;t.height=h;return t;}
int main(void){@autoreleasepool {
    events=[NSMutableArray new];FXDevice *device=[FXDevice new];
    __weak id oldFrame=nil;
    @autoreleasepool {
        HvDesktopFXPool *pool=[[HvDesktopFXPool alloc]initWithDevice:(id)device];assert(pool);
        HvDesktopFXLease *a=[pool acquireWidth:16 height:12 outputWidth:32 outputHeight:24];
        HvDesktopFXLease *b=[pool acquireWidth:16 height:12 outputWidth:32 outputHeight:24];
        HvDesktopFXLease *c=[pool acquireWidth:16 height:12 outputWidth:32 outputHeight:24];assert(a&&b&&c);
        assert(a.frame!=b.frame&&a.frame!=c.frame&&b.frame!=c.frame);
        assert(![pool acquireWidth:16 height:12 outputWidth:32 outputHeight:24]);
        assert((a.frame->input.usage&MTLTextureUsageRenderTarget) && (a.frame->output.usage&MTLTextureUsageShaderRead));
        oldFrame=a.frame;__weak id oldLease=a;
        [pool trim];a=nil;assert(!oldLease);b=nil;c=nil;
    }
    assert(!oldFrame); // strong property getters may autorelease until this drain
    @autoreleasepool {
        HvDesktopFXPool *budget=[[HvDesktopFXPool alloc]initWithDevice:(id)device];
        HvDesktopFXLease *a=[budget acquireWidth:16 height:12 outputWidth:32 outputHeight:24];
        HvDesktopFXLease *b=[budget acquireWidth:16 height:12 outputWidth:32 outputHeight:24];
        HvDesktopFXLease *c=[budget acquireWidth:16 height:12 outputWidth:32 outputHeight:24];assert(a&&b&&c);
        [budget setLimit:2];assert(![budget acquireWidth:16 height:12 outputWidth:32 outputHeight:24]);
        a=nil;assert([[budget valueForKey:@"_created"]unsignedIntegerValue]==2);
        b=nil;HvDesktopFXLease *d=[budget acquireWidth:16 height:12 outputWidth:32 outputHeight:24];assert(d&&d.frame!=c.frame);
        assert(![budget acquireWidth:16 height:12 outputWidth:32 outputHeight:24]);
        [budget setLimit:3];assert([budget acquireWidth:16 height:12 outputWidth:32 outputHeight:24]);
    }
    supported=NO;assert(![[HvDesktopFXPool alloc]initWithDevice:(id)device]);supported=YES;
    HvDesktopFXPool *pool=[[HvDesktopFXPool alloc]initWithDevice:(id)device];failTextures=YES;
    assert(![pool acquireWidth:16 height:12 outputWidth:32 outputHeight:24]);failTextures=NO;
    assert([pool acquireWidth:16 height:12 outputWidth:32 outputHeight:24]);
    FXRuntime *runtime=[FXRuntime new];
    HvMetal4Screen *screen=[[HvMetal4Screen alloc]initWithRuntime:(id)runtime device:(id)device library:nil bundle:nil];assert(screen);
    id source=texture(16,12),target=texture(32,24),cursor=texture(4,4);
    HvMetal4Job *(^encode)(uint64_t) = ^HvMetal4Job *(uint64_t epoch){
        float rect[]={-1,-1,0.25,0.25};
        [events removeAllObjects];return [screen encode:source target:target half:YES mode:1 cursor:cursor rect:rect sharp:YES imageEpoch:epoch upscale:YES];
    };
    HvMetal4Job *first=encode(1);assert(first);
    assert(([events isEqualToArray:@[@"render",@"draw",@"end",@"FX",@"render",@"draw",@"draw",@"end"]]));
    assert(atomic_load(&screen->fx_encoded)==1);[screen didCommit:YES];
    HvMetal4Job *second=encode(1);assert(second);
    assert(([events isEqualToArray:@[@"render",@"draw",@"draw",@"end"]]));
    assert(atomic_load(&screen->fx_reused)==1);[screen didCommit:YES];
    HvMetal4Job *third=encode(2);assert(third && atomic_load(&screen->fx_encoded)==2);
    [screen didCommit:NO];[third->keep removeAllObjects];third=nil;
    HvMetal4Job *retry=encode(2);assert(retry && atomic_load(&screen->fx_encoded)==3);[screen didCommit:YES];
    [screen setFXCacheAdmission:NO];HvMetal4Job *pressure=encode(3);assert(pressure);
    assert(![events containsObject:@"FX"] && atomic_load(&screen->fx_fallback)==1);
    assert(atomic_load(&screen->fx_pressure_fallback)==1);
    HvDesktopFXPool *screenPool=[screen valueForKey:@"_fxPool"];
    uint64_t trimEpoch=[[screenPool valueForKey:@"_epoch"]unsignedLongLongValue];
    for(unsigned i=0;i<100;i++)[screen setFXCacheAdmission:NO];
    assert([[screenPool valueForKey:@"_epoch"]unsignedLongLongValue]==trimEpoch);
    assert(!atomic_load(&screen->fx_resource_fallback) && !atomic_load(&screen->fx_size_fallback));
    // In-flight first/second still retain their leases after a pressure trim.
    assert(first->keep.count && second->keep.count);[first->keep removeAllObjects];[second->keep removeAllObjects];
    [retry->keep removeAllObjects];[pressure->keep removeAllObjects];
    [screen setFXCacheAdmission:YES];HvMetal4Job *recovery=encode(4);assert(recovery && [events containsObject:@"FX"]);
    [screen didCommit:NO];[recovery->keep removeAllObjects];
    id large=texture(32,24);
    [events removeAllObjects];
    HvMetal4Job *nativeSize=[screen encode:large target:target half:NO mode:0 cursor:nil rect:NULL sharp:NO imageEpoch:5 upscale:YES];assert(nativeSize);
    assert(![events containsObject:@"FX"] && atomic_load(&screen->fx_size_fallback)==1);
    [screen didCommit:NO];[nativeSize->keep removeAllObjects];
    [screen setFXCacheAdmission:NO];[screen setFXCacheAdmission:YES];
    failTextures=YES;HvMetal4Job *allocationFallback=encode(6);failTextures=NO;
    assert(allocationFallback && ![events containsObject:@"FX"]);
    assert(atomic_load(&screen->fx_resource_fallback)==1);
    assert(atomic_load(&screen->fx_fallback)==atomic_load(&screen->fx_pressure_fallback)+atomic_load(&screen->fx_resource_fallback)+atomic_load(&screen->fx_size_fallback));
    [screen didCommit:NO];[allocationFallback->keep removeAllObjects];
    HvMetal4Screen *retryScreen=[[HvMetal4Screen alloc]initWithRuntime:(id)runtime device:(id)device library:nil bundle:nil];assert(retryScreen);
    failCompiler=YES;[events removeAllObjects];
    HvMetal4Job *unavailable=[retryScreen encode:source target:target half:NO mode:0 cursor:nil rect:NULL sharp:NO imageEpoch:1 upscale:YES];
    assert(unavailable && ![events containsObject:@"FX"]);[retryScreen didCommit:NO];[unavailable->keep removeAllObjects];
    NSUInteger attempted=compilerCreations;
    HvMetal4Job *stillUnavailable=[retryScreen encode:source target:target half:NO mode:0 cursor:nil rect:NULL sharp:NO imageEpoch:1 upscale:YES];
    assert(stillUnavailable && compilerCreations==attempted);[retryScreen didCommit:NO];[stillUnavailable->keep removeAllObjects];
    failCompiler=NO;[retryScreen setFXCacheAdmission:NO];[retryScreen setFXCacheAdmission:YES];[events removeAllObjects];
    HvMetal4Job *compilerRecovery=[retryScreen encode:source target:target half:NO mode:0 cursor:nil rect:NULL sharp:NO imageEpoch:2 upscale:YES];
    assert(compilerRecovery && [events containsObject:@"FX"] && compilerCreations==attempted+1);[retryScreen didCommit:NO];[compilerRecovery->keep removeAllObjects];
    HvMetal4Screen *softScreen=[[HvMetal4Screen alloc]initWithRuntime:(id)runtime device:(id)device library:nil bundle:nil];assert(softScreen);
    [softScreen setFXCacheLimit:2];[events removeAllObjects];
    HvMetal4Job *softFirst=[softScreen encode:source target:target half:NO mode:0 cursor:nil rect:NULL sharp:NO imageEpoch:1 upscale:YES];
    assert(softFirst && [events containsObject:@"FX"]);[softScreen didCommit:YES];[softFirst->keep removeAllObjects];[events removeAllObjects];
    HvMetal4Job *softNext=[softScreen encode:source target:target half:NO mode:0 cursor:nil rect:NULL sharp:NO imageEpoch:2 upscale:YES];
    assert(softNext && [events containsObject:@"FX"]);[softScreen didCommit:YES];[softNext->keep removeAllObjects];[events removeAllObjects];
    HvMetal4Job *softCursor=[softScreen encode:source target:target half:NO mode:0 cursor:cursor rect:NULL sharp:NO imageEpoch:2 upscale:YES];
    assert(softCursor && ![events containsObject:@"FX"] && atomic_load(&softScreen->fx_reused)==1);[softScreen didCommit:YES];
    [softScreen setFXCacheLimit:0];[events removeAllObjects];
    HvMetal4Job *critical=[softScreen encode:source target:target half:NO mode:0 cursor:nil rect:NULL sharp:NO imageEpoch:3 upscale:YES];
    assert(critical && ![events containsObject:@"FX"] && atomic_load(&softScreen->fx_pressure_fallback)==1);
    assert(softCursor->keep.count);[softScreen didCommit:NO];[softCursor->keep removeAllObjects];[critical->keep removeAllObjects];
    puts("PASS Desktop MetalFX production routing: Metal4 encode, low-input colour pass, post-upscale cursor, committed-image reuse and rejected-image retry (recording objects; no GPU pixel claim)");
    puts("PASS Desktop MetalFX resource lifetime: three distinct bounded leases, declared texture usage, in-flight pressure protection, allocation failure and recovery");
    puts("PASS Desktop MetalFX pressure policy: repeated disabled frames do not retrim resources; pressure and geometry fallbacks independently attributed");
    puts("PASS Desktop MetalFX compiler recovery: failed initial pool creation retries after pressure recovery without per-frame compiler retries");
    puts("PASS Desktop MetalFX moderate pressure: two-lease cap reclaims spare and retiring frames, keeps new-image upscaling and cached cursor output, critical pressure still falls back safely");
}}
