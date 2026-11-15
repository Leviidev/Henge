#import <Foundation/Foundation.h>
#include "../devices/metal4_screen.h"
#include "../devices/pvg_screen.h"
#include <assert.h>
int main(void){@autoreleasepool {
    (void)hv_screen_pipeline; // shared shader header also defines the classic comparison helper
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device || ![MTLFXSpatialScalerDescriptor supportsMetal4FX:device]){
        puts("METAL4FX_UNAVAILABLE actual spatial upscaler pixels not validated on this GPU");return 78;
    }
    HvMetal4Runtime *runtime=[[HvMetal4Runtime alloc]initWithDevice:device];assert(runtime);
    id<MTLLibrary> lib=[device newLibraryWithSource:screen_shaders options:nil error:nil];assert(lib);
    HvMetal4Screen *screen=[[HvMetal4Screen alloc]initWithRuntime:runtime device:device library:lib bundle:nil];assert(screen);
    id<MTLCommandQueue> queue=[device newCommandQueue];os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:64 height:48 mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> source=[device newTextureWithDescriptor:d];
    _Float16 pixels[64*48*4];for(unsigned i=0;i<64*48;i++){
        pixels[4*i]=0.25;pixels[4*i+1]=0.5;pixels[4*i+2]=0.75;pixels[4*i+3]=1;
    }
    [source replaceRegion:MTLRegionMake2D(0,0,64,48) mipmapLevel:0 withBytes:pixels bytesPerRow:64*8];
    d.pixelFormat=MTLPixelFormatBGRA8Unorm;d.width=128;d.height=96;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> output=[device newTextureWithDescriptor:d];
    d.width=d.height=4;id<MTLTexture> cursor=[device newTextureWithDescriptor:d];
    uint8_t green[64];for(unsigned i=0;i<16;i++){green[4*i]=0;green[4*i+1]=255;green[4*i+2]=0;green[4*i+3]=255;}
    [cursor replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:green bytesPerRow:16];
    for(unsigned round=0;round<4;round++){
        uint32_t mode=round/2;float rect[]={-1,-1,0.25,0.25};
        HvMetal4Job *job=[screen encode:source target:output half:YES mode:mode cursor:cursor rect:rect sharp:YES imageEpoch:1 upscale:YES];assert(job);
        dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL success=NO;
        BOOL queued=[runtime commit:job classicQueue:queue lock:&lock drawable:nil completion:^(BOOL ok){success=ok;dispatch_semaphore_signal(done);}];
        [screen didCommit:queued];assert(queued);
        assert(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0 && success);
        uint8_t result[128*96*4];[output getBytes:result bytesPerRow:128*4 fromRegion:MTLRegionMake2D(0,0,128,96) mipmapLevel:0];
        const int expected[2][3]={{191,128,64},{225,188,137}};
        for(unsigned y=24;y<72;y+=8)for(unsigned x=24;x<104;x+=8)for(unsigned c=0;c<3;c++)
            assert(abs((int)result[4*(y*128+x)+c]-expected[mode][c])<=2);
        unsigned at=4*(90*128+4);assert(result[at]==0&&result[at+1]==255&&result[at+2]==0);
    }
    assert(atomic_load(&screen->fx_encoded)==2 && atomic_load(&screen->fx_reused)==2);
    puts("PASS actual Desktop MetalFX GPU: spatial output readback, encoded/linear half-float colour, sharp post-scale cursor and unchanged-image reuse");
}}
