#import <Foundation/Foundation.h>
static NSString *TestRoot;
#define HV_AGX_TEST_ROOT TestRoot
#import "pvg_agx_journal.h"
static int check(BOOL value,const char *message) {if(!value){fprintf(stderr,"check failed: %s\n",message);return 1;}return 0;}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=4)return 64;
    TestRoot=@(argv[1]);if([NSFileManager.defaultManager fileExistsAtPath:TestRoot])return 73;
    if(![NSFileManager.defaultManager createDirectoryAtPath:TestRoot withIntermediateDirectories:NO attributes:nil error:nil])return 73;
    NSData *a=[NSData dataWithContentsOfFile:@(argv[2])],*b=[NSData dataWithContentsOfFile:@(argv[3])];
    if(check(a&&b&&! [a isEqual:b],"two valid distinct ordinary libraries"))return 1;
    if(check(!hv_agx_library(a,hv_agx_hash(a),@"disabled-control"),"disabled gate"))return 1;
    [NSData.data writeToFile:[TestRoot stringByAppendingPathComponent:@"agx-journal-enable"] atomically:YES];
    id<MTLDevice>dev=MTLCreateSystemDefaultDevice();if(!dev)return 69;
    NSMutableArray *results=[NSMutableArray new];
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    NSMutableDictionary *attempt=[@{@"schema":@1,@"attempt":NSUUID.UUID.UUIDString,@"tag":@14,@"pid":@(getpid()),
       @"executable_identity":hv_agx_identity(),@"test_scope":@"helper-unit: two successful public-API compiles, manually exercise first/retry labels; no error-recovery or serialized-descriptor integration claim"}mutableCopy];
    NSUInteger i=0;
    for(NSData *bytes in @[a,b]) {
        NSError *error=nil;
        dispatch_data_t data=dispatch_data_create(bytes.bytes,bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        id<MTLLibrary>lib=[dev newLibraryWithData:data error:&error];if(check(lib!=nil,"library loads"))return 1;
        id<MTLFunction>v=[lib newFunctionWithName:@"journal_v"],f=[lib newFunctionWithName:@"journal_f"];
        if(check(v&&f,"functions resolve"))return 1;
        NSDictionary *provenance=hv_agx_library(bytes,hv_agx_hash(bytes),i?@"unit-second-candidate":@"unit-first-candidate");
        hv_agx_bind(v,provenance);hv_agx_bind(f,provenance);
        d.vertexFunction=v;d.fragmentFunction=f;
        NSDictionary *snapshot=hv_agx_descriptor(d,14);
        if(check([snapshot[@"fragment"][@"selected_bytes"][@"sha256"] isEqual:hv_agx_hash(bytes)],"selected-byte identity follows current function"))return 1;
        if(check([provenance[@"archive_status"] isEqual:@"saved"],"library archived"))return 1;
        NSString *archive=[[TestRoot stringByAppendingPathComponent:@"agx-journal"] stringByAppendingPathComponent:provenance[@"session"]];
        archive=[archive stringByAppendingPathComponent:provenance[@"file"]];
        if(check([[NSData dataWithContentsOfFile:archive]isEqual:bytes],"archived bytes exact"))return 1;
        hv_agx_phase(attempt,d,@{},i?@"retry_entered_driver":@"first_entered_driver",nil);
        id<MTLRenderPipelineState>p=[dev newRenderPipelineStateWithDescriptor:d error:&error];
        hv_agx_phase(attempt,d,@{},i?@"retry_created":@"first_created",error);
        if(check(p!=nil,"ordinary pipeline created"))return 1;
        [results addObject:@{@"created":@YES,@"selected_sha256":hv_agx_hash(bytes),@"snapshot":snapshot}];i++;
    }
    NSDictionary *report=@{@"passed":@YES,@"device":dev.name,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"normal_compiles":results,@"gpu_dispatched":@NO,@"lifetime_claim":@"metadata records IDs only; no deallocation timing assertion",@"scope":attempt[@"test_scope"]};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]writeToFile:[TestRoot stringByAppendingPathComponent:@"normal-test.json"] atomically:YES];return 0;
}}
