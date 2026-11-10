/* CPU-filled single-channel IOSurfaces sampled through Metal. Compare every
 * byte, including locations missed by the historical sparse content hash. */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

int main(void) { @autoreleasepool {
    NSApplicationLoad();
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    fprintf(stderr,"Metal device: %s\n",device.name.UTF8String ?: "none");
    if (!device) { puts("{\"passed\":false,\"error\":\"no Metal device\"}"); return 2; }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    NSMutableArray *cases = [NSMutableArray new];
    BOOL passed = YES;
    for (NSNumber *format in @[@(0x41303038u), @(0x4c303038u)]) {
      BOOL formatTested=NO;
      for (NSNumber *mode in @[@(MTLStorageModeShared), @(MTLStorageModeManaged), @(MTLStorageModePrivate)]) {
        const NSUInteger width=1280, height=720, row=1280;
        NSDictionary *props = @{(__bridge id)kIOSurfaceWidth:@(width),
            (__bridge id)kIOSurfaceHeight:@(height),
            (__bridge id)kIOSurfaceBytesPerRow:@(row),
            (__bridge id)kIOSurfaceBytesPerElement:@1,
            (__bridge id)kIOSurfaceAllocSize:@933888,
            (__bridge id)kIOSurfacePixelFormat:format};
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        NSMutableDictionary *entry = [@{@"fourcc":format, @"storage_mode":mode, @"surface_created":@(surface != NULL)} mutableCopy];
        [cases addObject:entry];
        if (!surface) { passed=NO; continue; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:width height:height mipmapped:NO];
        td.storageMode=mode.unsignedIntegerValue; td.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> texture=[device newTextureWithDescriptor:td iosurface:surface plane:0];
        entry[@"texture_created"]=@(texture != nil);
        if (!texture) { CFRelease(surface); continue; }
        formatTested=YES;
        id<MTLBuffer> output=[device newBufferWithLength:row*height options:MTLResourceStorageModeShared];
        NSMutableArray *rounds=[NSMutableArray new]; entry[@"rounds"]=rounds;
        for (NSUInteger round=0; round<2; round++) {
            IOSurfaceLock(surface,0,NULL);
            uint8_t *pixels=IOSurfaceGetBaseAddress(surface);
            size_t stride=IOSurfaceGetBytesPerRow(surface);
            if (!round) for (NSUInteger y=0;y<height;y++) for (NSUInteger x=0;x<width;x++)
                pixels[y*stride+x]=(uint8_t)((x*13+y*17+3)%251);
            else pixels[17*stride+25]^=0xff;
            IOSurfaceUnlock(surface,0,NULL);
            memset(output.contents,0xCC,row*height);
            id<MTLCommandBuffer> cb=[queue commandBuffer];
            id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
            [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:output destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*height];
            [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
            NSUInteger mismatches=0;
            const uint8_t *actual=output.contents;
            for (NSUInteger y=0;y<height;y++) for (NSUInteger x=0;x<width;x++) {
                uint8_t expected=(uint8_t)((x*13+y*17+3)%251);
                if (round && y==17 && x==25) expected^=0xff;
                mismatches+=actual[y*row+x]!=expected;
            }
            BOOL ok=cb.status==MTLCommandBufferStatusCompleted && !mismatches;
            [rounds addObject:@{@"round":@(round), @"mismatched_bytes":@(mismatches),
                @"status":@(cb.status), @"error":cb.error.description ?: @"", @"passed":@(ok)}];
            passed &= ok;
        }
        CFRelease(surface);
      }
      passed &= formatTested;
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(passed), @"cases":cases} options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(json.bytes,1,json.length,stdout); puts("");
    return passed ? 0 : 1;
} }
