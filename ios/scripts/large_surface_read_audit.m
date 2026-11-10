/* CPU seeds large IOSurfaces; GPU only reads them, writing a small result
 * buffer. Exercises page-list boundaries without GPU writes to large maps. */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <Foundation/Foundation.h>
static void pattern(uint8_t *p,unsigned row,BOOL last){
    p[0]=(row*17+3)&255;p[1]=(row>>8)&255;p[2]=(row+7)&255;p[3]=255;
    if(last){p[0]^=0xa5;p[1]^=0x5a;p[2]^=0x33;}
}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2)return 2;NSApplicationLoad();
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)return 3;
    NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nkernel void readRows(texture2d<float,access::read> tex [[texture(0)]], device uint4 *out [[buffer(0)]], uint y [[thread_position_in_grid]]) { if(y>=tex.get_height())return; out[y*2]=uint4(round(tex.read(uint2(0,y))*255.0f)); out[y*2+1]=uint4(round(tex.read(uint2(tex.get_width()-1,y))*255.0f)); }";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> pipeline=library?[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"readRows"] error:&error]:nil;
    if(!pipeline){fprintf(stderr,"pipeline: %s\n",error.description.UTF8String);return 4;}
    id<MTLCommandQueue> queue=[device newCommandQueue];NSMutableArray *rows=[NSMutableArray new];BOOL passed=YES;
    for(NSNumber *heightNumber in @[@4095,@4096,@4097,@8193,@6016]){@autoreleasepool{
        unsigned height=heightNumber.unsignedIntValue,width=height==6016?6016:4096;size_t rowBytes=width*4;
        IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{(__bridge id)kIOSurfaceWidth:@(width),(__bridge id)kIOSurfaceHeight:@(height),(__bridge id)kIOSurfaceBytesPerElement:@4,(__bridge id)kIOSurfaceBytesPerRow:@(rowBytes),(__bridge id)kIOSurfaceAllocSize:@(rowBytes*height),(__bridge id)kIOSurfacePixelFormat:@((uint32_t)0x42475241)});
        if(!surface)return 5;
        if(IOSurfaceLock(surface,0,NULL)!=kIOReturnSuccess)return 6;
        uint8_t *base=IOSurfaceGetBaseAddress(surface);rowBytes=IOSurfaceGetBytesPerRow(surface);
        memset(base,0x40,IOSurfaceGetAllocSize(surface));
        for(unsigned y=0;y<height;y++){pattern(base+y*rowBytes,y,NO);pattern(base+y*rowBytes+(width-1)*4,y,YES);}
        IOSurfaceUnlock(surface,0,NULL);
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> texture=[device newTextureWithDescriptor:desc iosurface:surface plane:0];
        if(!texture)return 7;
        id<MTLBuffer> result=[device newBufferWithLength:height*8*sizeof(uint32_t) options:MTLResourceStorageModeShared];
        memset(result.contents,0xcd,result.length);
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> enc=[cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];[enc setTexture:texture atIndex:0];[enc setBuffer:result offset:0 atIndex:0];
        [enc dispatchThreads:MTLSizeMake(height,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];[enc endEncoding];[cb commit];[cb waitUntilCompleted];
        uint32_t *values=result.contents;NSUInteger bad=0,cpuBad=0;NSMutableArray *first=[NSMutableArray new];
        IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL);
        for(unsigned y=0;y<height;y++)for(unsigned edge=0;edge<2;edge++){
            uint8_t bytes[4];pattern(bytes,y,edge!=0);unsigned expected[]={bytes[2],bytes[1],bytes[0],bytes[3]};BOOL mismatch=NO;
            for(unsigned c=0;c<4;c++)if(values[y*8+edge*4+c]!=expected[c])mismatch=YES;
            if(mismatch){bad++;if(first.count<12)[first addObject:@{@"row":@(y),@"edge":@(edge),@"actual":@[@(values[y*8+edge*4]),@(values[y*8+edge*4+1]),@(values[y*8+edge*4+2]),@(values[y*8+edge*4+3])]}];}
            if(memcmp(base+y*rowBytes+(edge?(width-1)*4:0),bytes,4))cpuBad++;
        }
        IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);
        BOOL ok=cb.status==MTLCommandBufferStatusCompleted&&!bad&&!cpuBad;passed&=ok;
        [rows addObject:@{@"width":@(width),@"height":@(height),@"row_bytes":@(rowBytes),@"allocation":@(IOSurfaceGetAllocSize(surface)),@"bad_gpu_samples":@(bad),@"bad_cpu_samples":@(cpuBad),@"first_mismatches":first,@"status":@(cb.status),@"error":cb.error.description?:@"",@"passed":@(ok)}];
        CFRelease(surface);
    }}
    NSDictionary *report=@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"device":device.name,@"gpu_access":@"large surfaces read-only; small output buffer",@"cases":rows,@"passed":@(passed)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];[data writeToFile:@(argv[1]) atomically:YES];return passed?0:8;
}}
