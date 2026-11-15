#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <unistd.h>
#include "../devices/metal4_screen.h"
#include "../devices/pvg_screen.h"
static BOOL waitJob(HvMetal4Runtime *runtime,HvMetal4Job *job,id<MTLCommandQueue> queue,os_unfair_lock *lock){
    if(!job)return NO;dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL ok=NO;
    BOOL accepted=[runtime commit:job classicQueue:queue lock:lock drawable:nil completion:^(BOOL good){ok=good;dispatch_semaphore_signal(done);}];
    return accepted&&!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))&&ok;
}
int main(void){@autoreleasepool{
    alarm(60);NSApplicationLoad();id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device){NSArray *all=MTLCopyAllDevices();if(all.count==1)device=all[0];}
    HvMetal4Runtime *runtime=[[HvMetal4Runtime alloc]initWithDevice:device];
    if(!runtime){fprintf(stderr,"METAL4_UNAVAILABLE actual display pixels not validated\n");return 78;}
    NSError *error=nil;id<MTLLibrary> library=[device newLibraryWithSource:screen_shaders options:nil error:&error];
    HvMetal4Screen *screen=[[HvMetal4Screen alloc]initWithRuntime:runtime device:device library:library bundle:nil];
    if(!screen){fprintf(stderr,"Metal4 display pipeline error: %s\n",error.description.UTF8String);return 1;}
    id<MTLCommandQueue> queue=[device newCommandQueue];os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> source=[device newTextureWithDescriptor:d],reference=[device newTextureWithDescriptor:d],actual=[device newTextureWithDescriptor:d];
    uint8_t pixels[64];for(unsigned i=0;i<16;i++){pixels[i*4]=17+i*5;pixels[i*4+1]=32+i*3;pixels[i*4+2]=64+i*2;pixels[i*4+3]=255;}
    [source replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;
    id<MTLSamplerState> sampler=[device newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *hd=[d copy];hd.pixelFormat=MTLPixelFormatRGBA16Float;
    id<MTLTexture> high=[device newTextureWithDescriptor:hd],cursor=[device newTextureWithDescriptor:d];
    _Float16 hp[64];for(unsigned i=0;i<64;i++)hp[i]=(_Float16)((i%16)/15.0f);
    [high replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:hp bytesPerRow:32];
    uint8_t cursorPixels[64];for(unsigned i=0;i<16;i++){cursorPixels[i*4]=32;cursorPixels[i*4+1]=64;cursorPixels[i*4+2]=96;cursorPixels[i*4+3]=128;}
    [cursor replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:cursorPixels bytesPerRow:16];
    for(unsigned round=0;round<24;round++){
        BOOL half=round%3!=0,showCursor=round%2;uint32_t mode=round%3==2?1:0;
        id<MTLTexture> texture=half?high:source;float cursorRect[]={-0.5f,-0.5f,1,1};
        id<MTLCommandBuffer> cb=[queue commandBuffer];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture=reference;pass.colorAttachments[0].loadAction=MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:pass];
        [e setRenderPipelineState:hv_screen_pipeline(device,library,half?@"screen_linear":@"screen_plain",NO,&error)];
        float rect[]={-1,-1,2,2};[e setVertexBytes:rect length:sizeof rect atIndex:0];
        [e setFragmentTexture:texture atIndex:0];[e setFragmentSamplerState:sampler atIndex:0];
        [e setFragmentBytes:&mode length:sizeof mode atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        if(showCursor){[e setRenderPipelineState:hv_screen_pipeline(device,library,@"screen_cursor",YES,&error)];[e setVertexBytes:cursorRect length:sizeof cursorRect atIndex:0];[e setFragmentTexture:cursor atIndex:0];[e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];}
        [e endEncoding];
        os_unfair_lock_lock(&lock);[cb commit];os_unfair_lock_unlock(&lock);
        HvMetal4Job *job=[screen encode:texture target:actual half:half mode:mode cursor:showCursor?cursor:nil rect:showCursor?cursorRect:NULL sharp:NO];
        if(!waitJob(runtime,job,queue,&lock))return 2;
        uint8_t a[64],b[64];[reference getBytes:a bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
        [actual getBytes:b bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
        if(memcmp(a,b,sizeof a)){fprintf(stderr,"Metal4 display mismatch round=%u\n",round);return 3;}
    }
    puts("PASS actual Metal4 display: byte-identical classic/Metal4 GPU pixels, half-float/gamma/cursor alpha and 24 allocator/uniform/table reuse cycles");return 0;
}}
