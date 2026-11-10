/* Native Metal integration for the production copyback encoder. Deliberately
 * different guest/host strides and nonzero allocation/plane offsets. */
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#include <assert.h>
#include <unistd.h>
#include "../devices/pvg_surface_copyback.h"
static NSUInteger bad(const uint8_t *a,const uint8_t *b,NSUInteger n){NSUInteger k=0;for(NSUInteger i=0;i<n;i++)k+=a[i]!=b[i];return k;}
int main(int argc,char **argv){@autoreleasepool{
    BOOL skip=argc==2&&!strcmp(argv[1],"--skip-copyback");alarm(45);NSApplicationLoad();id<MTLDevice>d=MTLCreateSystemDefaultDevice();assert(d);
    id<MTLCommandQueue>q=[d newCommandQueue];NSUInteger compared=0,cases=0;BOOL all=YES;
    for(NSNumber*f in @[@(0x34323066u),@(0x34323076u),@(0x78663230u),@(0x78343230u)])for(NSNumber*n in @[@256,@258]){@autoreleasepool{
        NSUInteger w=n.unsignedIntegerValue,h=w==256?128:130;BOOL ten=f.unsignedIntValue==0x78663230u||f.unsignedIntValue==0x78343230u;
        CVPixelBufferRef pb=NULL;assert(CVPixelBufferCreate(kCFAllocatorDefault,w,h,f.unsignedIntValue,(__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{},(__bridge id)kCVPixelBufferMetalCompatibilityKey:@YES},&pb)==0);
        IOSurfaceRef surf=CVPixelBufferGetIOSurface(pb);assert(IOSurfaceGetPlaneCount(surf)==2);
        NSMutableArray *textures=[NSMutableArray new],*views=[NSMutableArray new],*inputs=[NSMutableArray new];HvPvgSurfaceCopyback plan[2];uint64_t offsets[2],rows[2],heights[2],widths[2],bpes[2];uint64_t alloc=64,first=128;
        for(NSUInteger p=0;p<2;p++){
            widths[p]=IOSurfaceGetWidthOfPlane(surf,p);heights[p]=IOSurfaceGetHeightOfPlane(surf,p);bpes[p]=(ten?2:1)*(p?2:1);
            rows[p]=((widths[p]*bpes[p]+63)&~63ull)+64;offsets[p]=alloc;alloc+=rows[p]*heights[p]+64;
            MTLPixelFormat fmt=ten?(p?MTLPixelFormatRG16Unorm:MTLPixelFormatR16Unorm):(p?MTLPixelFormatRG8Unorm:MTLPixelFormatR8Unorm);
            MTLTextureDescriptor*td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:widths[p] height:heights[p] mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsagePixelFormatView;
            id<MTLTexture>t=[d newTextureWithDescriptor:td iosurface:surf plane:p];assert(t);id<MTLTexture>v=[t newTextureViewWithPixelFormat:fmt];assert(v);[textures addObject:t];[views addObject:v];
            NSUInteger inrow=(widths[p]*bpes[p]+255)&~255ull;id<MTLBuffer>in=[d newBufferWithLength:inrow*heights[p] options:MTLResourceStorageModeShared];assert(in);[inputs addObject:in];
        }
        uint64_t length=(first+alloc+0x3fff)&~0x3fffull;id<MTLBuffer>guest=[d newBufferWithLength:length options:MTLResourceStorageModeShared],shadow=[d newBufferWithLength:alloc options:MTLResourceStorageModeShared];assert(guest&&shadow);
        NSMutableData*expected=[NSMutableData dataWithLength:length];memset(expected.mutableBytes,0xE9,length);memset(guest.contents,0xE9,length);memset(shadow.contents,0xE9,alloc);
        for(NSUInteger p=0;p<2;p++)assert(hv_pvg_surface_copyback_plan(first,alloc,length,offsets[p],rows[p],widths[p],heights[p],bpes[p],&plan[p]));
        assert(CVPixelBufferLockBaseAddress(pb,0)==0);
        for(NSUInteger p=0;p<2;p++)memset(CVPixelBufferGetBaseAddressOfPlane(pb,p),0xE9,CVPixelBufferGetBytesPerRowOfPlane(pb,p)*heights[p]);
        assert(CVPixelBufferUnlockBaseAddress(pb,0)==0);
        for(NSUInteger round=0;round<3;round++){
            if(round==1){/* A sparse CPU edit after the preceding GPU result. */
                uint64_t at=first+offsets[0]+3*rows[0]+13;((uint8_t*)guest.contents)[at]^=0x5A;((uint8_t*)expected.mutableBytes)[at]^=0x5A;
                assert(memcmp(shadow.contents,(uint8_t*)guest.contents+first,alloc)!=0);
                assert(CVPixelBufferLockBaseAddress(pb,0)==0);
                for(NSUInteger p=0;p<2;p++)for(NSUInteger y=0;y<heights[p];y++)memcpy((uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pb,p)+y*CVPixelBufferGetBytesPerRowOfPlane(pb,p),(uint8_t*)guest.contents+first+offsets[p]+y*rows[p],widths[p]*bpes[p]);
                assert(CVPixelBufferUnlockBaseAddress(pb,0)==0);memcpy(shadow.contents,(uint8_t*)guest.contents+first,alloc);
            }
            id<MTLCommandBuffer>cb=[q commandBuffer];id<MTLBlitCommandEncoder>e=[cb blitCommandEncoder];
            for(NSUInteger p=0;p<2;p++){
                if(round==1&&p==0)continue; /* Verify plane0 and CPUedit survive a plane1-only write. */
                NSUInteger x=round?8:0,y=round?4:0,ww=round?12:widths[p],hh=round?8:heights[p];NSUInteger inrow=(widths[p]*bpes[p]+255)&~255ull;id<MTLBuffer>in=inputs[p];
                for(NSUInteger yy=0;yy<hh;yy++)for(NSUInteger xx=0;xx<ww*bpes[p];xx++){
                    uint8_t value=(uint8_t)(xx*37+yy*17+p*53+round*11+0x37);((uint8_t*)in.contents)[yy*inrow+xx]=value;
                    ((uint8_t*)expected.mutableBytes)[first+offsets[p]+(yy+y)*rows[p]+x*bpes[p]+xx]=value;
                }
                [e copyFromBuffer:in sourceOffset:0 sourceBytesPerRow:inrow sourceBytesPerImage:inrow*hh sourceSize:MTLSizeMake(ww,hh,1) toTexture:views[p] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x,y,0)];
            }
            [e endEncoding];e=[cb blitCommandEncoder];
            for(NSUInteger p=0;p<2;p++)if(!(round==1&&p==0)&&!skip)assert(hv_pvg_encode_surface_copyback(e,textures[p],guest,round==2?nil:shadow,&plan[p]));
            [e endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
            NSUInteger gb=bad(guest.contents,expected.bytes,length),sb=round==2?0:bad(shadow.contents,(const uint8_t*)expected.bytes+first,alloc);
            compared+=length+(round==2?0:alloc);BOOL good=skip?(gb>0&&(round==2||sb>0)):(gb==0&&sb==0);all&=good;
            printf("format=%08x size=%lux%lu round=%lu guest_bad=%lu shadow_bad=%lu absent_shadow=%d check=%s\n",f.unsignedIntValue,(unsigned long)w,(unsigned long)h,(unsigned long)round,(unsigned long)gb,(unsigned long)sb,round==2,good?"pass":"FAIL");
        }
        cases++;CVPixelBufferRelease(pb);
    }}
    printf("cases=%lu compared_bytes=%lu negative_control=%d passed=%d\n",(unsigned long)cases,(unsigned long)compared,skip,all);return all?0:1;
}}
