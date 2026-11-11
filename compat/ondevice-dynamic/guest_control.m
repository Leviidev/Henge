#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <string.h>
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=4)return 64;
    NSString *root=@(argv[1]),*kind=@(argv[2]);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSError *error=nil;
    NSString *file=[root stringByAppendingPathComponent:[@"consumer-" stringByAppendingString:[kind stringByAppendingString:@".metallib"]]];
    id<MTLLibrary> consumer=[device newLibraryWithURL:[NSURL fileURLWithPath:file] error:&error];
    if(!consumer) { fprintf(stderr,"consumer: %s\n",error.description.UTF8String); return 1; }
    MTLComputePipelineDescriptor *descriptor=[MTLComputePipelineDescriptor new];
    descriptor.computeFunction=[consumer newFunctionWithName:@"dynamic_consumer"];
    if([kind isEqual:@"preloaded"] || [kind isEqual:@"absolute"]) {
        NSString *dependencyFile=[kind isEqual:@"preloaded"]?@"dynamic-control.metallib":@"dynamic-absolute.metallib";
        id<MTLDynamicLibrary> dependency=[device newDynamicLibraryWithURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:dependencyFile]] error:&error];
        if(!dependency) { fprintf(stderr,"dependency: %s\n",error.description.UTF8String); return 2; }
        descriptor.preloadedLibraries=@[dependency];
    }
    id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithDescriptor:descriptor options:0 reflection:nil error:&error];
    if(!pipeline) { fprintf(stderr,"pipeline: %s\n",error.description.UTF8String); return 3; }
    id<MTLBuffer> buffer=[device newBufferWithLength:256*4 options:MTLResourceStorageModeShared];
    memset(buffer.contents,0,buffer.length);
    id<MTLCommandBuffer> command=[[device newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline]; [encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(256,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    unsigned mismatches=0;
    for(unsigned i=0;i<256;++i)if(((uint32_t *)buffer.contents)[i]!=i*7+19)++mismatches;
    NSDictionary *report=@{@"schema":@1,@"mismatches":@(mismatches),@"expected_values":@256,
        @"command_status":@(command.status),@"scope":@"native API adapter through private Unix HTTP service; no guest qualification"};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:@(argv[3]) atomically:YES];
    return mismatches||command.status!=MTLCommandBufferStatusCompleted;
}}
