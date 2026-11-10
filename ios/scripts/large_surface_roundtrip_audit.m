/* Read verification gates GPU writes into large IOSurfaces.
 * Every pixel written by the GPU is then checked through the CPU mapping. */
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
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nkernel void readRows(texture2d<float,access::read> tex [[texture(0)]], device uint4 *out [[buffer(0)]], uint y [[thread_position_in_grid]]) { if(y>=tex.get_height())return; out[y*2]=uint4(round(tex.read(uint2(0,y))*255.0f)); out[y*2+1]=uint4(round(tex.read(uint2(tex.get_width()-1,y))*255.0f)); }\nkernel void writePixels(texture2d<float,access::write> tex [[texture(0)]], uint2 p [[thread_position_in_grid]]) { if(p.x>=tex.get_width() || p.y>=tex.get_height())return; uint r=(p.x*3+p.y*5+7)&255; uint g=(p.x+p.y*11+13)&255; uint b=(p.x*17+p.y+19)&255; tex.write(float4(r,g,b,255)/255.0f,p); }";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> pipeline=library?[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"readRows"] error:&error]:nil;
    id<MTLComputePipelineState> writer=library?[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"writePixels"] error:&error]:nil;
    if(!pipeline || !writer){fprintf(stderr,"pipeline: %s\n",error.description.UTF8String);return 4;}
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
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
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
        BOOL readOK=cb.status==MTLCommandBufferStatusCompleted&&!bad&&!cpuBad;
        NSUInteger badWrite=0;BOOL writeOK=NO;
        if(readOK){
            id<MTLCommandBuffer> writeCB=[queue commandBuffer];id<MTLComputeCommandEncoder> we=[writeCB computeCommandEncoder];
            [we setComputePipelineState:writer];[we setTexture:texture atIndex:0];
            [we dispatchThreads:MTLSizeMake(width,height,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
            [we endEncoding];[writeCB commit];[writeCB waitUntilCompleted];
            writeOK=writeCB.status==MTLCommandBufferStatusCompleted;
            IOSurfaceLock(surface,kIOSurfaceLockReadOnly,NULL);
            for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++){
                const uint8_t *pixel=base+y*rowBytes+x*4;
                uint8_t expected[]={ (x*17+y+19)&255, (x+y*11+13)&255, (x*3+y*5+7)&255,255 };
                if(memcmp(pixel,expected,4))badWrite++;
            }
            IOSurfaceUnlock(surface,kIOSurfaceLockReadOnly,NULL);
            writeOK&=badWrite==0;
        }
        BOOL ok=readOK&&writeOK;passed&=ok;
        [rows addObject:@{@"read_gate_passed":@(readOK),@"gpu_write_passed":@(writeOK),@"bad_cpu_pixels_after_gpu_write":@(badWrite),@"checked_write_pixels":@((uint64_t)width*height),@"width":@(width),@"height":@(height),@"row_bytes":@(rowBytes),@"allocation":@(IOSurfaceGetAllocSize(surface)),@"bad_gpu_samples":@(bad),@"bad_cpu_samples":@(cpuBad),@"first_mismatches":first,@"status":@(cb.status),@"error":cb.error.description?:@"",@"passed":@(ok)}];
        CFRelease(surface);
    }}
    NSDictionary *report=@{@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"device":device.name,@"gpu_access":@"read gate then GPU writes; full CPU pixel verification",@"cases":rows,@"passed":@(passed)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];[data writeToFile:@(argv[1]) atomically:YES];return passed?0:8;
}}
