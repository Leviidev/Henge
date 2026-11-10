/* Exercise updates outside the old 8-of-64-byte IOSurface change hash.
 * Round 0: initial CPU pixels. Round 1: one unsampled active byte per plane.
 * Round 2: also change a sampled byte; stale copies must not heal only here. */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
int main(void){@autoreleasepool{
    NSApplicationLoad();id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device){puts("{\"passed\":false,\"error\":\"no Metal device\"}");return 2;}
    id<MTLCommandQueue> queue=[device newCommandQueue];NSMutableArray *cases=[NSMutableArray new];BOOL passed=YES;
    for(NSNumber *format in @[@(0x34323066u),@(0x34323076u),@(0x78663230u),@(0x78343230u)]){
        BOOL ten=format.unsignedIntValue==0x78663230u||format.unsignedIntValue==0x78343230u;
        CVPixelBufferRef pixel=NULL;CVReturn created=CVPixelBufferCreate(kCFAllocatorDefault,256,128,format.unsignedIntValue,
            (__bridge CFDictionaryRef)@{(__bridge id)kCVPixelBufferIOSurfacePropertiesKey:@{},(__bridge id)kCVPixelBufferMetalCompatibilityKey:@YES},&pixel);
        NSMutableDictionary *entry=[@{@"fourcc":format,@"create":@(created),@"rounds":[NSMutableArray new]} mutableCopy];[cases addObject:entry];
        if(created||!pixel){passed=NO;continue;}
        IOSurfaceRef surface=CVPixelBufferGetIOSurface(pixel);NSUInteger planes=IOSurfaceGetPlaneCount(surface);entry[@"planes"]=@(planes);
        if(planes!=2){passed=NO;CVPixelBufferRelease(pixel);continue;}
        NSMutableArray *textures=[NSMutableArray new],*outputs=[NSMutableArray new],*offsets=[NSMutableArray new];
        BOOL valid=YES;
        for(NSUInteger plane=0;plane<2;plane++){
            NSUInteger w=IOSurfaceGetWidthOfPlane(surface,plane),h=IOSurfaceGetHeightOfPlane(surface,plane);
            MTLPixelFormat pf=ten?(plane?MTLPixelFormatRG16Unorm:MTLPixelFormatR16Unorm):(plane?MTLPixelFormatRG8Unorm:MTLPixelFormatR8Unorm);
            MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
            id<MTLTexture> tex=[device newTextureWithDescriptor:td iosurface:surface plane:plane];
            if(!tex){valid=NO;break;}[textures addObject:tex];
            NSUInteger bpe=(ten?2:1)*(plane?2:1);[outputs addObject:[device newBufferWithLength:w*h*bpe options:MTLResourceStorageModeShared]];
        }
        entry[@"textures_created"]=@(valid);
        if(!valid){passed=NO;CVPixelBufferRelease(pixel);continue;}
        CVPixelBufferLockBaseAddress(pixel,0);
        uintptr_t base=(uintptr_t)IOSurfaceGetBaseAddress(surface);
        for(NSUInteger plane=0;plane<2;plane++){
            uint8_t *p=CVPixelBufferGetBaseAddressOfPlane(pixel,plane);NSUInteger row=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane),h=CVPixelBufferGetHeightOfPlane(pixel,plane);
            memset(p,plane?0x80:0x50,row*h);
            NSUInteger offset=8;while((((uintptr_t)p-base+offset)%64)<8)offset++;
            [offsets addObject:@(offset)];
        }
        CVPixelBufferUnlockBaseAddress(pixel,0);entry[@"unsampled_offsets"]=offsets;
        for(NSUInteger round=0;round<3;round++){
            CVPixelBufferLockBaseAddress(pixel,0);
            if(round==1)for(NSUInteger plane=0;plane<2;plane++){
                uint8_t *p=CVPixelBufferGetBaseAddressOfPlane(pixel,plane);p[[offsets[plane] unsignedIntegerValue]]^=0x40;
            }
            if(round==2)((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixel,0))[0]^=0x40;
            NSMutableArray *expected=[NSMutableArray new];
            for(NSUInteger plane=0;plane<2;plane++){
                id<MTLTexture> tex=textures[plane];NSUInteger bpe=(ten?2:1)*(plane?2:1),row=tex.width*bpe;
                NSMutableData *data=[NSMutableData dataWithLength:row*tex.height];uint8_t *p=CVPixelBufferGetBaseAddressOfPlane(pixel,plane);NSUInteger stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,plane);
                for(NSUInteger y=0;y<tex.height;y++)memcpy((uint8_t *)data.mutableBytes+y*row,p+y*stride,row);
                [expected addObject:data];
            }
            CVPixelBufferUnlockBaseAddress(pixel,0);
            id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
            for(NSUInteger plane=0;plane<2;plane++){
                id<MTLTexture> tex=textures[plane];id<MTLBuffer> out=outputs[plane];NSUInteger row=tex.width*(ten?2:1)*(plane?2:1);
                memset(out.contents,0xCC,out.length);
                [e copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(tex.width,tex.height,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*tex.height];
            }
            [e endEncoding];[cb commit];[cb waitUntilCompleted];
            NSMutableArray *counts=[NSMutableArray new];BOOL ok=cb.status==MTLCommandBufferStatusCompleted;
            for(NSUInteger plane=0;plane<2;plane++){
                id<MTLBuffer> out=outputs[plane];NSData *ref=expected[plane];NSUInteger bad=0;const uint8_t *a=out.contents,*b=ref.bytes;
                for(NSUInteger i=0;i<ref.length;i++)bad+=a[i]!=b[i];[counts addObject:@(bad)];ok&=!bad;
            }
            [entry[@"rounds"] addObject:@{@"round":@(round),@"mismatched_bytes_by_plane":counts,@"status":@(cb.status),@"error":cb.error.description?:@"",@"passed":@(ok)}];passed&=ok;
        }
        CVPixelBufferRelease(pixel);
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"device":device.name,@"passed":@(passed),@"cases":cases} options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);puts("");return passed?0:1;
}}
