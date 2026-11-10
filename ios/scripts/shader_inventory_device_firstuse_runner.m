/* Isolated inventory validation. Shipped candidates are never dispatched. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#include <stdatomic.h>
#include <unistd.h>

static NSString *ReportRoot;
static atomic_bool AuditDone;
#if TARGET_OS_OSX
static BOOL AppKitInitialized;
#endif
static NSString *Digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *s=[NSMutableString string];for(unsigned i=0;i<sizeof(bytes);i++)[s appendFormat:@"%02x",bytes[i]];return s;
}
static void Save(id value,NSString *name) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[ReportRoot stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}
static void Phase(NSString *job,NSString *phase) { Save(@{@"job":job,@"phase":phase,@"time":@([NSDate date].timeIntervalSince1970)},@"inventory-current.json"); }
static NSData *Asset(NSString *resources,NSString *file,NSString *hash) {
    if(![file isEqual:file.lastPathComponent])return nil;
    NSData *data=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:file]];
    return data && [Digest(data) isEqual:hash]?data:nil;
}
static id<MTLLibrary> Library(id<MTLDevice> device,NSData *data,NSError **error) {
    if(!data)return nil;
    dispatch_data_t bytes=dispatch_data_create(data.bytes,data.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    return [device newLibraryWithData:bytes error:error];
}
static NSDictionary *Counts(NSArray *names) { NSMutableDictionary *counts=[NSMutableDictionary new];for(NSString *name in names)counts[name]=@([counts[name] unsignedIntegerValue]+1);return counts; }
static NSArray *Constants(id<MTLFunction> function) {
    NSMutableArray *out=[NSMutableArray new];
    for(NSString *key in [[function.functionConstantsDictionary allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        MTLFunctionConstant *c=function.functionConstantsDictionary[key];
        [out addObject:@{@"name":c.name,@"index":@(c.index),@"data_type":@(c.type),@"required":@(c.required)}];
    }return out;
}
static NSDictionary *DispatchOracle(id<MTLDevice> device,id<MTLComputePipelineState> pipeline,NSUInteger base,NSUInteger multiplier,NSUInteger add) {
    const NSUInteger count=256;
    id<MTLBuffer> buffer=[device newBufferWithLength:count*sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if(!buffer)return @{@"dispatch_completed":@NO,@"error":@"buffer_allocation_failed"};
    memset(buffer.contents,0xAA,buffer.length);
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    if(!encoder)return @{@"dispatch_completed":@NO,@"error":@"encoder_creation_failed"};
    [encoder setComputePipelineState:pipeline];[encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(64,pipeline.maxTotalThreadsPerThreadgroup),1,1)];
    [encoder endEncoding];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){dispatch_semaphore_signal(done);}];[command commit];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC)))return @{@"dispatch_completed":@NO,@"status":@"command_timeout",@"halt_requested":@YES};
    unsigned mismatches=0;uint32_t *actual=buffer.contents;
    for(NSUInteger i=0;i<count;i++)if(actual[i]!=(uint32_t)(base+multiplier*i+add))mismatches++;
    BOOL completed=command.status==MTLCommandBufferStatusCompleted;
    return @{@"dispatch_completed":@(completed),@"command_error":command.error.description?:@"",@"elements_checked":@(count),
             @"mismatches":@(mismatches),@"readback_exact":@(completed&&mismatches==0),
             @"actual_sha256":Digest([NSData dataWithBytes:buffer.contents length:buffer.length])};
}
static NSDictionary *TileOracle(id<MTLDevice> device,id<MTLFunction> function,uint32_t nonce) {
    NSMutableDictionary *r=[@{@"dispatch_api":@"dispatchThreadsPerTile",@"width":@16,@"height":@16,@"pixel_format":@"RGBA8Unorm",@"clear_rgba8":@[@255,@0,@255,@255],@"supports_apple4":@([device supportsFamily:MTLGPUFamilyApple4])} mutableCopy];
    NSError *error=nil;MTLTileRenderPipelineDescriptor *descriptor=[MTLTileRenderPipelineDescriptor new];descriptor.tileFunction=function;descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;descriptor.rasterSampleCount=1;descriptor.threadgroupSizeMatchesTileSize=YES;
    Phase(@"tile",@"tile_pipeline_creation");id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithTileDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
    r[@"pipeline_created"]=@(pipeline!=nil);r[@"pipeline_error"]=error.description?:@"";if(!pipeline)return r;
    r[@"imageblock_sample_length"]=@(pipeline.imageblockSampleLength);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> texture=[device newTextureWithDescriptor:td];id<MTLBuffer> buffer=[device newBufferWithLength:256*16 options:MTLResourceStorageModeShared];
    if(!texture||!buffer){r[@"error"]=@"resource_allocation_failed";return r;}memset(buffer.contents,0xAA,buffer.length);
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(1,0,1,1);pass.tileWidth=16;pass.tileHeight=16;pass.imageblockSampleLength=pipeline.imageblockSampleLength;
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> command=[queue commandBuffer];Phase(@"tile",@"encode_tile_dispatch");id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder){r[@"error"]=@"render_encoder_failed";return r;}
    [encoder setRenderPipelineState:pipeline];[encoder dispatchThreadsPerTile:MTLSizeMake(16,16,1)];[encoder endEncoding];r[@"tile_dispatch_encoded"]=@YES;
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];[blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:4096];[blit endEncoding];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);[command addCompletedHandler:^(id<MTLCommandBuffer> c){dispatch_semaphore_signal(done);}];Phase(@"tile",@"commit_wait_readback");[command commit];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))){r[@"halt_requested"]=@YES;r[@"error"]=@"command_timeout";return r;}
    NSMutableData *pixels=[NSMutableData dataWithLength:1024];uint8_t *actual=pixels.mutableBytes;for(unsigned y=0;y<16;y++)memcpy(actual+y*64,(uint8_t *)buffer.contents+y*256,64);
    unsigned mismatches=0,unchanged=0;for(uint32_t i=0;i<256;i++){uint32_t v=nonce^(i*0x045d9f3bu);for(unsigned c=0;c<4;c++)if(actual[4*i+c]!=(uint8_t)(v>>(8*c)))mismatches++;if(actual[4*i]==255&&actual[4*i+1]==0&&actual[4*i+2]==255&&actual[4*i+3]==255)unchanged++;}
    BOOL completed=command.status==MTLCommandBufferStatusCompleted;r[@"dispatch_completed"]=@(completed);r[@"command_error"]=command.error.description?:@"";r[@"pixels_checked"]=@256;r[@"bytes_checked"]=@1024;r[@"mismatched_bytes"]=@(mismatches);r[@"clear_sentinel_pixels"]=@(unchanged);r[@"actual_sha256"]=Digest(pixels);r[@"readback_exact"]=@(completed&&mismatches==0&&unchanged<256);[pixels writeToFile:[ReportRoot stringByAppendingPathComponent:@"tile-readback.rgba8"] atomically:YES];return r;
}
static NSDictionary *FirstUseCase(id<MTLDevice> device,NSDictionary *manifest,NSString *selected,NSString *resources) {
    NSMutableDictionary *r=[@{@"id":selected,@"origin":@"authored",@"results":[NSMutableArray new],@"conversion_route":@"unknown_requires_host_receipts"} mutableCopy];
    NSDictionary *spec=manifest[@"cases"][selected];NSString *file=spec[@"file"];NSData *data=Asset(resources,file,manifest[@"asset_sha256"][file]);r[@"asset_hash_matches"]=@(data!=nil);r[@"input_sha256"]=manifest[@"asset_sha256"][file];r[@"library_route"]=spec[@"route"];if(!data)return r;
    NSError *error=nil;Phase(selected,@"library_creation");id<MTLLibrary> lib=nil;
    if([selected isEqual:@"basic"]){MTLCompileOptions *options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion3_1;lib=[device newLibraryWithSource:[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding] options:options error:&error];}else lib=Library(device,data,&error);
    r[@"library_loaded"]=@(lib!=nil);r[@"library_error"]=error.description?:@"";r[@"function_names"]=lib.functionNames?:@[];if(!lib)return r;
    NSArray *keys=[selected isEqual:@"packed"]?@[@"alpha",@"beta"]:@[[selected isEqual:@"static"]?@"static_consumer":selected];uint32_t nonce=[manifest[@"nonce_value"] unsignedIntValue];
    for(NSString *key in keys)for(unsigned mode=0;mode<([selected isEqual:@"packed"]?2:1);mode++) {
        NSString *name=manifest[@"names"][key];NSMutableDictionary *row=[@{@"name":name,@"key":key,@"mode":@(mode)} mutableCopy];[(NSMutableArray *)r[@"results"] addObject:row];error=nil;Phase(selected,[@"function_" stringByAppendingString:name]);id<MTLFunction> function=nil;
        if([selected isEqual:@"packed"]){BOOL value=mode;MTLFunctionConstantValues *values=[MTLFunctionConstantValues new];[values setConstantValue:&value type:MTLDataTypeBool atIndex:0];function=[lib newFunctionWithName:name constantValues:values error:&error];row[@"constant_index"]=@0;row[@"constant_type"]=@"bool";}else function=[lib newFunctionWithName:name];
        row[@"function_created"]=@(function!=nil);row[@"function_error"]=error.description?:@"";if(!function)continue;
        row[@"function_type"]=@(function.functionType);
        if([selected isEqual:@"tile"]){row[@"tile_execution"]=TileOracle(device,function,nonce);if([row[@"tile_execution"][@"halt_requested"] boolValue])break;continue;}
        error=nil;Phase(selected,@"compute_pipeline_creation");id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&error];row[@"pipeline_created"]=@(pipeline!=nil);row[@"pipeline_error"]=error.description?:@"";
        if(pipeline){Phase(selected,@"authored_dispatch");NSUInteger add=[selected isEqual:@"packed"]?(1000*mode+([key isEqual:@"beta"]?10000:0)):[selected isEqual:@"static"]?11:0;NSUInteger mul=[selected isEqual:@"basic"]?17:[selected isEqual:@"static"]?29:1;row[@"execution"]=DispatchOracle(device,pipeline,nonce,mul,add);if([row[@"execution"][@"halt_requested"] boolValue])break;}
        Save(r,@"firstuse-case-current.json");
    }return r;
}
static NSString *Argument(NSArray *args,NSString *flag,NSString *fallback) { NSUInteger i=[args indexOfObject:flag];return i!=NSNotFound&&i+1<args.count?args[i+1]:fallback; }
static NSDictionary *Run(NSString *resources,NSString *output,NSArray *args) { @autoreleasepool {
    NSString *runID=NSUUID.UUID.UUIDString;ReportRoot=[output stringByAppendingPathComponent:runID];[[NSFileManager defaultManager]createDirectoryAtPath:ReportRoot withIntermediateDirectories:YES attributes:nil error:nil];atomic_store(&AuditDone,false);
    NSData *latest=[NSJSONSerialization dataWithJSONObject:@{@"run_id":runID,@"relative_directory":runID} options:NSJSONWritingPrettyPrinted error:nil];[latest writeToFile:[output stringByAppendingPathComponent:@"firstuse-latest.json"] options:NSDataWritingAtomic error:nil];
    NSData *bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:@"firstuse-manifest.json"]];NSDictionary *manifest=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;NSString *selected=Argument(args,@"--firstuse-case",@"");
    NSMutableDictionary *report=[@{@"schema":@1,@"kit":@"inventory-firstuse-04",@"run_id":runID,@"selected_case":selected,@"manifest_sha256":bytes?Digest(bytes):@"",@"nonce":manifest[@"nonce"]?:@"",@"status":@"running",@"shipped_kernels_dispatched":@NO,@"os":NSProcessInfo.processInfo.operatingSystemVersionString,@"conversion_route":@"unknown_requires_host_receipts"} mutableCopy];Save(report,@"firstuse-report.json");
    if(!manifest||![manifest[@"allowed_cases"] containsObject:selected]){report[@"status"]=@"invalid_manifest_or_case";goto finish;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{if(!atomic_load(&AuditDone)){Save(@{@"status":@"watchdog_timeout",@"seconds":@90},@"firstuse-timeout.json");_exit(124);}});
    @try {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
#if TARGET_OS_OSX
        NSArray *available=MTLCopyAllDevices();report[@"startup"]=@{@"appkit_load_succeeded":@(AppKitInitialized),@"default_device_available":@(device!=nil),@"enumerated_device_count":@(available.count)};if(!device)device=available.firstObject;
#endif
        report[@"device"]=device.name?:@"none";if(!device){report[@"status"]=@"no_metal_device";goto finish;}
        report[@"result"]=FirstUseCase(device,manifest,selected,resources);report[@"status"]=@"complete_results_require_review";
    }@catch(NSException *exception){report[@"status"]=@"exception";report[@"exception"]=exception.description;}
finish:atomic_store(&AuditDone,true);Save(report,@"firstuse-report.json");return report;
} }
#if TARGET_OS_IOS
@interface InventoryDeviceDelegate:UIResponder<UIApplicationDelegate>
@property(strong,nonatomic)UIWindow *window;
@end
@implementation InventoryDeviceDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[[UILabel alloc]initWithFrame:vc.view.bounds];label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;label.numberOfLines=0;label.textAlignment=NSTextAlignmentCenter;label.text=@"Shader Inventory Validation\nRunning bounded stage";[vc.view addSubview:label];self.window.rootViewController=vc;[self.window makeKeyAndVisible];app.idleTimerDisabled=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *resources=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"AuditAssets"];
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSDictionary *r=Run(resources,[documents stringByAppendingPathComponent:@"inventory-firstuse-04"],NSProcessInfo.processInfo.arguments);
        dispatch_async(dispatch_get_main_queue(),^{label.text=[NSString stringWithFormat:@"Shader Inventory Validation\n%@\nResults require stage-by-stage review",r[@"status"]];app.idleTimerDisabled=NO;});
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(InventoryDeviceDelegate.class));}}
#else
int main(int argc,char **argv){@autoreleasepool{if(argc<3)return 64;AppKitInitialized=NSApplicationLoad();NSDictionary *r=Run(@(argv[1]),@(argv[2]),NSProcessInfo.processInfo.arguments);puts([[r description] UTF8String]);return [r[@"status"] isEqual:@"complete_results_require_review"]?0:1;}}
#endif
