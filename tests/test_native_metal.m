#import "pvg_screen.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static NSData *render(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLLibrary> lib,
                      id<MTLTexture> input, BOOL half, uint32_t mode, BOOL cursor) {
    NSError *error = nil;
    id<MTLRenderPipelineState> pipe = hv_screen_pipeline(device, lib, half ? @"screen_linear" : @"screen_plain", NO, &error);
    assert(pipe && !error);
    NSUInteger width = input.width, height = input.height;
    NSUInteger row = (width * 4 + 255) & ~(NSUInteger)255;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> output = [device newTextureWithDescriptor:td];
    assert(output);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = output;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd];
    float rect[4] = {-1,-1,2,2};
    [e setRenderPipelineState:pipe];
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    [e setFragmentTexture:input atIndex:0];
    [e setFragmentSamplerState:sampler atIndex:0];
    if (half) [e setFragmentBytes:&mode length:sizeof mode atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    if (cursor) {
        uint8_t pixel[4] = {0,0,128,128}; // premultiplied red over the screen
        MTLTextureDescriptor *ctd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
        ctd.storageMode = MTLStorageModeShared;
        ctd.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> ctex = [device newTextureWithDescriptor:ctd];
        [ctex replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:pixel bytesPerRow:4];
        [e setRenderPipelineState:hv_screen_pipeline(device, lib, @"screen_cursor", YES, &error)];
        assert(!error);
        [e setFragmentTexture:ctex atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [e endEncoding];
    id<MTLBuffer> readback = [device newBufferWithLength:row * height options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1)
                toBuffer:readback destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * height];
    [blit endEncoding];
    [cb commit]; [cb waitUntilCompleted]; // test readback only; production remains asynchronous
    assert(cb.status == MTLCommandBufferStatusCompleted);
    NSMutableData *result = [NSMutableData dataWithLength:width * height * 4];
    for (NSUInteger y = 0; y < height; y++)
        memcpy((uint8_t *)result.mutableBytes + y * width * 4,
               (uint8_t *)readback.contents + y * row, width * 4);
    return result;
}

int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { fprintf(stderr, "Native Metal pixel tests require a GPU; no pass claimed.\n"); return 77; }
    NSError *error = nil;
    id<MTLLibrary> bundled = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
    assert(bundled && !error);
    id<MTLLibrary> fallback = [device newLibraryWithSource:screen_shaders options:nil error:&error];
    assert(fallback && !error);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    for (id<MTLLibrary> lib in @[bundled, fallback]) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2 height:2 mipmapped:NO];
        td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> input = [device newTextureWithDescriptor:td];
        uint8_t pattern[16] = {255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255};
        [input replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:pattern bytesPerRow:8];
        assert([render(device,queue,lib,input,NO,0,NO) isEqualToData:[NSData dataWithBytes:pattern length:16]]);
        NSData *overlaid = render(device,queue,lib,input,NO,0,YES);
        const uint8_t *overlay = overlaid.bytes;
        assert(abs(overlay[0]-127)<=1 && overlay[1]==0 && abs(overlay[2]-128)<=1 && overlay[3]==255);
        td.pixelFormat = MTLPixelFormatRGBA16Float;
        input = [device newTextureWithDescriptor:td];
        uint16_t gray[16];
        for (int i=0;i<16;i++) gray[i] = i%4==3 ? 0x3c00 : 0x3400; // 1.0 alpha, 0.25 RGB
        [input replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:gray bytesPerRow:16];
        for (uint32_t mode=0;mode<2;mode++) {
            NSData *pixels = render(device,queue,lib,input,YES,mode,NO);
            const uint8_t *p = pixels.bytes;
            for (int i=0;i<16;i++) assert(abs(p[i]-(i%4==3 ? 255 : mode ? 137 : 64))<=1);
        }
        // An exact Fit mode need not have a height divisible by eight. Verify
        // every pixel and the last scanline through both production libraries.
        td.pixelFormat = MTLPixelFormatBGRA8Unorm;
        td.width = 1920; td.height = 1350;
        input = [device newTextureWithDescriptor:td]; assert(input);
        NSMutableData *full = [NSMutableData dataWithLength:1920 * 1350 * 4];
        uint8_t *bytes = full.mutableBytes;
        for (NSUInteger y=0;y<1350;y++) for (NSUInteger x=0;x<1920;x++) {
            NSUInteger at=(y*1920+x)*4;
            bytes[at]=x%251; bytes[at+1]=y%253; bytes[at+2]=(x+y)%255; bytes[at+3]=255;
        }
        [input replaceRegion:MTLRegionMake2D(0,0,1920,1350) mipmapLevel:0 withBytes:bytes bytesPerRow:1920*4];
        assert([render(device,queue,lib,input,NO,0,NO) isEqualToData:full]);
    }
    puts("native Metal exact-fit: 1920x1350 non-eight-aligned height, every pixel and final row preserved");
    printf("native Metal GPU pixels: bundled and fallback libraries, BGRA orientation/colours, half-float encoded/linear and premultiplied cursor passed on %s\n",device.name.UTF8String);
    return 0;
} }
