#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "HGStatelessLink.h"
#include <CommonCrypto/CommonDigest.h>

static NSString *sha(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString new];
    for (unsigned char byte : digest) [value appendFormat:@"%02x", byte];
    return value;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 4 || argc > 6) return 64; // consumer dependency new-output [preloaded-mask] [source-origin-empty]
    NSString *out = @(argv[3]);
    if ([NSFileManager.defaultManager fileExistsAtPath:out]) return 65;
    [NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *consumer = [NSData dataWithContentsOfFile:@(argv[1])];
    NSData *dependency = [NSData dataWithContentsOfFile:@(argv[2])];
    if (!consumer || !dependency) return 66;
    const void *inputs[] = {consumer.bytes, dependency.bytes};
    size_t sizes[] = {consumer.length, dependency.length};
    const char *origins[] = {argc == 6 ? "" : argv[1], argv[2]};
    uint32_t preloaded = argc >= 5 ? (uint32_t)strtoul(argv[4], nullptr, 0) : 0;
    void *output = nullptr; size_t length = 0; char *failure = nullptr;
    int ios = 0;
#ifdef HG_STATELESS_DEVICE_CONTROL
    ios = 1;
#endif
    int linked = HGStatelessMetallibClose(inputs, sizes, origins, 2, preloaded,
        "dynamic_consumer", ios, &output, &length, &failure);
    if (linked) { fprintf(stderr, "%s\n", failure ?: "closure rejected"); free(failure); return 1; }
    NSData *libraryBytes = [NSData dataWithBytesNoCopy:output length:length freeWhenDone:YES];
    [libraryBytes writeToFile:[out stringByAppendingPathComponent:@"closed.metallib"] atomically:YES];
    NSError *error = nil;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    dispatch_data_t data = dispatch_data_create(libraryBytes.bytes, libraryBytes.length, nullptr,
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
    if (!library) { fprintf(stderr, "library: %s\n", error.description.UTF8String); return 2; }
    id<MTLFunction> function = [library newFunctionWithName:@"dynamic_consumer"];
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) { fprintf(stderr, "pipeline: %s\n", error.description.UTF8String); return 3; }
    id<MTLBuffer> buffer = [device newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared];
    memset(buffer.contents, 0, buffer.length);
    id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline]; [encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(256,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
    unsigned mismatches = 0;
    for (unsigned i = 0; i < 256; ++i) if (((uint32_t *)buffer.contents)[i] != i * 7 + 19) ++mismatches;
    NSDictionary *report = @{@"schema":@1, @"scope":@"authored stateless compute; direct native Metal API",
        @"consumer_sha256":sha(consumer), @"dependency_sha256":sha(dependency),
        @"output_sha256":sha(libraryBytes), @"library_loaded":@YES, @"pipeline_created":@YES,
        @"expected_values":@256, @"mismatches":@(mismatches), @"device":device.name,
        @"command_status":@(command.status), @"command_error":command.error.description ?: @"",
        @"external_compiler_invoked":@NO, @"retargeted_to_ios":@(ios),
        @"henge_guest_integration_qualified":@NO};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[out stringByAppendingPathComponent:@"report.json"] atomically:YES];
    fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
    return mismatches || command.status != MTLCommandBufferStatusCompleted;
}}
