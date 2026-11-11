#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <AppKit/AppKit.h>
#include <unistd.h>
#include "../devices/pvg_store_action.h"

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2)return 64; alarm(45);
    NSApplicationLoad();
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSArray *devices=MTLCopyAllDevices();
    if(!device && devices.count==1)device=devices.firstObject;
    NSMutableDictionary *report=[@{@"device":device.name?:@"",@"cases":[NSMutableArray new]}mutableCopy];
    if(!device){[report setObject:@"no_metal_device" forKey:@"error"];[[NSJSONSerialization dataWithJSONObject:report options:0 error:nil]writeToFile:@(argv[1]) atomically:YES];return 69;}
    id<MTLCommandQueue> queue=[device newCommandQueue];
    for(NSNumber *width in @[@4,@64])for(NSNumber *late in @[@NO,@YES]) { @autoreleasepool {
        NSUInteger w=width.unsignedIntegerValue,h=4;
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        id<MTLTexture> texture=[device newTextureWithDescriptor:desc];
        NSMutableData *seed=[NSMutableData dataWithLength:w*h*4];uint8_t *s=seed.mutableBytes;
        for(NSUInteger i=0;i<w*h;i++){s[i*4]=17;s[i*4+1]=34;s[i*4+2]=51;s[i*4+3]=255;}
        [texture replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:seed.bytes bytesPerRow:w*4];
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
        pass.colorAttachments[0].storeAction=late.boolValue?MTLStoreActionUnknown:MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(.25,.5,.75,1);
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> encoder=[cb renderCommandEncoderWithDescriptor:pass];
        if(late.boolValue) { const uint32_t record[]={1,0}; if(!hv_pvg_apply_store_action(encoder,102,record,sizeof record))return 70; }
        [encoder endEncoding];[cb commit];[cb waitUntilCompleted];
        NSMutableData *pixels=[NSMutableData dataWithLength:w*h*4];memset(pixels.mutableBytes,165,pixels.length);
        [texture getBytes:pixels.mutableBytes bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
        uint8_t *v=pixels.mutableBytes;NSUInteger mismatch=0;const uint8_t expected[]={64,128,191,255};
        for(NSUInteger i=0;i<pixels.length;i++)if(v[i]!=expected[i%4])mismatch++;
        [report[@"cases"]addObject:@{@"width":width,@"late_store":late,@"texture_created":@(texture!=nil),@"encoder_created":@(encoder!=nil),@"command_status":@(cb.status),@"command_error":cb.error.description?:@"",@"rgba":@[@(v[0]),@(v[1]),@(v[2]),@(v[3])],@"mismatched_bytes":@(mismatch),@"bytes":@(pixels.length)}];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:@(argv[1]) options:NSDataWritingAtomic error:nil];
    }}
    alarm(0);for(NSDictionary *c in report[@"cases"])if([c[@"mismatched_bytes"]unsignedIntegerValue] || ![c[@"encoder_created"]boolValue])return 1;return 0;
} }
