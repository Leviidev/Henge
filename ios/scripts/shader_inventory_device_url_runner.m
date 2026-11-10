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
static NSDictionary *PackedControl(id<MTLDevice> device,NSDictionary *asset,NSString *resources) {
    NSMutableDictionary *r=[@{@"origin":@"authored",@"cases":[NSMutableArray new]} mutableCopy];
    NSData *data=Asset(resources,asset[@"file"],asset[@"sha256"]);r[@"asset_hash_matches"]=@(data!=nil);
    if(!data)return r;NSError *error=nil;Phase(@"packed-control",@"library_load");id<MTLLibrary> lib=Library(device,data,&error);
    r[@"library_loaded"]=@(lib!=nil);r[@"library_error"]=error.description?:@"";r[@"names"]=lib.functionNames?:@[];
    if(!lib)return r;
    BOOL all=YES;
    for(NSString *name in @[@"alpha",@"beta"])for(int mode=0;mode<2;mode++) {
        NSMutableDictionary *c=[@{@"name":name,@"mode":@(mode),@"constant_index":@0,@"constant_type":@"bool"} mutableCopy];
        [(NSMutableArray *)r[@"cases"] addObject:c];Phase(@"packed-control",[NSString stringWithFormat:@"specialize_%@_%d",name,mode]);
        BOOL value=mode;MTLFunctionConstantValues *values=[MTLFunctionConstantValues new];[values setConstantValue:&value type:MTLDataTypeBool atIndex:0];
        error=nil;id<MTLFunction> function=[lib newFunctionWithName:name constantValues:values error:&error];
        c[@"function_created"]=@(function!=nil);c[@"function_error"]=error.description?:@"";
        error=nil;id<MTLComputePipelineState> pipeline=function?[device newComputePipelineStateWithFunction:function error:&error]:nil;
        c[@"pipeline_created"]=@(pipeline!=nil);c[@"pipeline_error"]=error.description?:@"";
        if(pipeline){Phase(@"packed-control",@"authored_dispatch");NSDictionary *dispatch=DispatchOracle(device,pipeline,[name isEqual:@"alpha"]?1000:2000,1,100*mode);c[@"execution"]=dispatch;all&=[dispatch[@"readback_exact"] boolValue];if([dispatch[@"halt_requested"] boolValue]){r[@"halt_requested"]=@YES;return r;}}
        else all=NO;
    }r[@"all_specializations_exact"]=@(all);return r;
}
static NSDictionary *DynamicControl(id<MTLDevice> device,NSDictionary *asset,NSString *resources) {
    BOOL attempt=[NSProcessInfo.processInfo.arguments containsObject:@"--attempt-unadvertised-dynamic"];
    NSMutableDictionary *r=[@{@"origin":@"authored",@"supports_dynamic_libraries":@(device.supportsDynamicLibraries),
        @"attempt_unadvertised_dynamic":@(attempt),@"dynamic_loading_route":@"file_url",@"consumer_loading_route":@"runtime_source"} mutableCopy];
    @try {
        NSData *data=Asset(resources,asset[@"file"],asset[@"sha256"]);
        NSData *consumer=Asset(resources,asset[@"consumer_file"],asset[@"consumer_sha256"]);r[@"asset_hash_matches"]=@(data&&consumer);
        if(!data||!consumer){r[@"dynamic_status"]=@"asset_hash_failed";return r;}
        if(!device.supportsDynamicLibraries&&!attempt){r[@"dynamic_status"]=@"not_attempted_advertised_unsupported";return r;}
        r[@"dynamic_status"]=@"attempting_authored_api";
        NSError *error=nil;Phase(@"dynamic-control",@"byte_library_load_probe");id<MTLLibrary> byteLibrary=Library(device,data,&error);
        r[@"byte_load_probe"]=@{@"library_loaded":@(byteLibrary!=nil),@"error":error.description?:@"",@"pipeline_status":@"not_attempted_in_this_probe"};
        error=nil;Phase(@"dynamic-control",@"url_library_load");NSURL *url=[NSURL fileURLWithPath:[resources stringByAppendingPathComponent:asset[@"file"]]];
        id<MTLLibrary> lib=[device newLibraryWithURL:url error:&error];r[@"library_url"]=url.absoluteString;
        r[@"library_loaded"]=@(lib!=nil);r[@"library_error"]=error.description?:@"";if(!lib){r[@"dynamic_status"]=@"url_library_rejected";return r;}
        error=nil;Phase(@"dynamic-control",@"url_dynamic_object_creation");id<MTLDynamicLibrary> dynamic=[device newDynamicLibrary:lib error:&error];
        r[@"dynamic_created"]=@(dynamic!=nil);r[@"dynamic_error"]=error.description?:@"";if(!dynamic){r[@"dynamic_status"]=@"dynamic_object_rejected";return r;}
        MTLCompileOptions *options=[MTLCompileOptions new];options.libraries=@[dynamic];options.languageVersion=MTLLanguageVersion3_1;
        error=nil;Phase(@"dynamic-control",@"runtime_consumer_compile_link");id<MTLLibrary> client=[device newLibraryWithSource:[[NSString alloc]initWithData:consumer encoding:NSUTF8StringEncoding] options:options error:&error];
        r[@"consumer_library_created"]=@(client!=nil);r[@"consumer_error"]=error.description?:@"";if(!client){r[@"dynamic_status"]=@"consumer_compile_rejected";return r;}
        id<MTLFunction> function=[client newFunctionWithName:@"dynamic_consumer"];r[@"consumer_function_created"]=@(function!=nil);if(!function){r[@"dynamic_status"]=@"consumer_function_rejected";return r;}
        MTLComputePipelineDescriptor *descriptor=[MTLComputePipelineDescriptor new];descriptor.computeFunction=function;descriptor.preloadedLibraries=@[dynamic];
        error=nil;Phase(@"dynamic-control",@"runtime_consumer_pipeline_link");id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
        r[@"consumer_pipeline_created"]=@(pipeline!=nil);r[@"pipeline_error"]=error.description?:@"";
        if(pipeline){Phase(@"dynamic-control",@"authored_dispatch");r[@"execution"]=DispatchOracle(device,pipeline,0,7,19);r[@"dynamic_status"]=[r[@"execution"][@"readback_exact"] boolValue]?@"authored_readback_exact":@"authored_execution_failed";}
        else r[@"dynamic_status"]=@"consumer_pipeline_rejected";
    }@catch(NSException *exception){r[@"dynamic_status"]=@"exception";r[@"exception"]=exception.description;}
    return r;
}
static NSDictionary *Candidate(id<MTLDevice> device,NSDictionary *job,NSString *resources,BOOL pipelines) {
    NSMutableDictionary *r=[@{@"id":job[@"id"],@"sha256":job[@"sha256"],@"source_sha256":job[@"source_sha256"],
       @"origin":@"shipped_candidate",@"execution_status":@"not_tested_no_argument_contract",@"pixel_verified":@NO,
       @"functions":[NSMutableArray new]} mutableCopy];
    NSData *data=Asset(resources,job[@"file"],job[@"sha256"]);r[@"asset_hash_matches"]=@(data!=nil);if(!data)return r;
    NSError *error=nil;Phase(job[@"id"],@"library_load");id<MTLLibrary> lib=Library(device,data,&error);
    r[@"library_loaded"]=@(lib!=nil);r[@"library_error"]=error.description?:@"";if(!lib)return r;
    r[@"actual_library_type"]=@(lib.type);r[@"library_type_matches"]=@(lib.type==([job[@"library_type"] intValue]==2?MTLLibraryTypeDynamic:MTLLibraryTypeExecutable));
    NSMutableArray *expected=[NSMutableArray new];for(NSDictionary *f in job[@"expected_functions"])[expected addObject:f[@"name"]];
    r[@"actual_function_names"]=lib.functionNames;r[@"name_multiplicity_matches"]=@([Counts(expected) isEqual:Counts(lib.functionNames)]);
    if([job[@"library_type"] intValue]==2) {
        r[@"consumer_link_status"]=@"not_tested_no_consumer_contract";r[@"supports_dynamic_libraries"]=@(device.supportsDynamicLibraries);
        if(device.supportsDynamicLibraries){Phase(job[@"id"],@"dynamic_object_creation");error=nil;id<MTLDynamicLibrary> dynamic=[device newDynamicLibrary:lib error:&error];r[@"dynamic_created"]=@(dynamic!=nil);r[@"dynamic_error"]=error.description?:@"";}
        return r;
    }
    if(!pipelines){r[@"pipeline_status"]=@"not_requested";return r;}
    NSArray *samples=job[@"pipeline_samples"];if(samples.count>4){r[@"pipeline_status"]=@"sample_bound_exceeded";return r;}
    for(NSDictionary *sample in samples) {
        NSMutableDictionary *f=[@{@"name":sample[@"name"],@"declared_type":sample[@"type_raw"]} mutableCopy];[(NSMutableArray *)r[@"functions"] addObject:f];
        Phase(job[@"id"],[@"function_" stringByAppendingString:sample[@"name"]]);id<MTLFunction> function=[lib newFunctionWithName:sample[@"name"]];
        f[@"function_created"]=@(function!=nil);if(!function)continue;
        f[@"actual_type"]=@(function.functionType);f[@"constants"]=Constants(function);
        BOOL required=NO;for(NSDictionary *c in f[@"constants"])required|=[c[@"required"] boolValue];
        if(required){f[@"pipeline_status"]=@"not_tested_required_constants_without_contract";continue;}
        if(function.functionType!=MTLFunctionTypeKernel){f[@"pipeline_status"]=@"not_tested_render_descriptor_required";continue;}
        Phase(job[@"id"],[@"pipeline_" stringByAppendingString:sample[@"name"]]);error=nil;id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&error];
        f[@"pipeline_created"]=@(pipeline!=nil);f[@"pipeline_error"]=error.description?:@"";
    }return r;
}
static NSString *Argument(NSArray *args,NSString *flag,NSString *fallback) { NSUInteger i=[args indexOfObject:flag];return i!=NSNotFound&&i+1<args.count?args[i+1]:fallback; }
static NSDictionary *Run(NSString *resources,NSString *output,NSArray *args) { @autoreleasepool {
    NSString *runID=NSUUID.UUID.UUIDString;
    ReportRoot=[output stringByAppendingPathComponent:runID];[[NSFileManager defaultManager]createDirectoryAtPath:ReportRoot withIntermediateDirectories:YES attributes:nil error:nil];atomic_store(&AuditDone,false);
    NSData *latest=[NSJSONSerialization dataWithJSONObject:@{@"run_id":runID,@"relative_directory":runID} options:NSJSONWritingPrettyPrinted error:nil];
    [latest writeToFile:[output stringByAppendingPathComponent:@"inventory-latest.json"] options:NSDataWritingAtomic error:nil];
    NSData *bytes=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:@"inventory-jobs.json"]];
    NSDictionary *manifest=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
    NSString *stage=Argument(args,@"--inventory-stage",@"controls"),*selected=Argument(args,@"--inventory-job",@"");
    NSMutableDictionary *report=[@{@"schema":@1,@"kit":@"inventory-device-03",@"stage":stage,@"selection":selected,
        @"run_id":runID,
        @"manifest_sha256":bytes?Digest(bytes):@"",@"status":@"running",@"jobs":[NSMutableArray new],
        @"shipped_kernels_dispatched":@NO,@"os":NSProcessInfo.processInfo.operatingSystemVersionString} mutableCopy];
    Save(report,@"inventory-report.json");
    if(!manifest||![manifest[@"allowed_stages"] containsObject:stage]){report[@"status"]=@"invalid_manifest_or_stage";goto finish;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        if(!atomic_load(&AuditDone)){Save(@{@"status":@"watchdog_timeout",@"seconds":@90,@"current_checkpoint":@"inventory-current.json"},@"inventory-timeout.json");_exit(124);}
    });
    @try {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
#if TARGET_OS_OSX
        NSArray<id<MTLDevice>> *available=MTLCopyAllDevices();
        NSMutableArray *deviceNames=[NSMutableArray new];for(id<MTLDevice> candidate in available)[deviceNames addObject:candidate.name?:@"unnamed"];
        report[@"startup"]=@{@"revision":@"appkit-v2",@"appkit_load_succeeded":@(AppKitInitialized),
            @"main_thread":@(NSThread.isMainThread),@"default_device_available":@(device!=nil),
            @"enumerated_devices":deviceNames,@"device_selection":device?@"system_default":available.count?@"enumerated_first":@"none"};
        if(!device)device=available.firstObject;
#endif
        report[@"device"]=device.name?:@"none";if(!device){report[@"status"]=@"no_metal_device";goto finish;}
        if([stage isEqual:@"controls"]) {
            NSDictionary *packed=PackedControl(device,manifest[@"controls"][@"packed"],resources);report[@"packed_control"]=packed;Save(report,@"inventory-report.json");
            if(![packed[@"halt_requested"] boolValue])report[@"dynamic_control"]=DynamicControl(device,manifest[@"controls"][@"dynamic"],resources);
        } else {
            NSMutableArray *jobs=[NSMutableArray new];for(NSDictionary *job in manifest[@"jobs"])if(!selected.length||[job[@"id"] hasPrefix:selected])[jobs addObject:job];
            if((selected.length&&jobs.count!=1)||jobs.count>7){report[@"status"]=@"invalid_or_ambiguous_selection";goto finish;}
            report[@"expected_jobs"]=@(jobs.count);
            for(NSDictionary *job in jobs) { @autoreleasepool {
                NSDictionary *result=Candidate(device,job,resources,[stage isEqual:@"pipelines"]);[(NSMutableArray *)report[@"jobs"] addObject:result];Save(report,@"inventory-report.json");
            }}
        }report[@"status"]=@"complete_results_require_review";
    }@catch(NSException *exception){report[@"status"]=@"exception";report[@"exception"]=exception.description;}
finish:
    atomic_store(&AuditDone,true);Save(report,@"inventory-report.json");return report;
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
        NSDictionary *r=Run(resources,[documents stringByAppendingPathComponent:@"inventory-device-03"],NSProcessInfo.processInfo.arguments);
        dispatch_async(dispatch_get_main_queue(),^{label.text=[NSString stringWithFormat:@"Shader Inventory Validation\n%@\nResults require stage-by-stage review",r[@"status"]];app.idleTimerDisabled=NO;});
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(InventoryDeviceDelegate.class));}}
#else
int main(int argc,char **argv){@autoreleasepool{if(argc<3)return 64;AppKitInitialized=NSApplicationLoad();NSDictionary *r=Run(@(argv[1]),@(argv[2]),NSProcessInfo.processInfo.arguments);puts([[r description] UTF8String]);return [r[@"status"] isEqual:@"complete_results_require_review"]?0:1;}}
#endif
