/* Isolated iPad preflight: library/function loading, compute pipeline creation,
 * and authored controls. Framework shaders are never dispatched with guessed
 * resources. Resource hashes bind results to the actual bytes tested. */
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <CommonCrypto/CommonDigest.h>

@protocol AuditMetalSerialization
- (id)newRenderPipelineDescriptorWithSerializedData:(dispatch_data_t)data deserializationContext:(id)context;
- (id)newTileRenderPipelineDescriptorWithSerializedData:(dispatch_data_t)data deserializationContext:(id)context;
@end
@interface AuditFunctionResolver : NSObject
@property(strong) NSDictionary *functions;
@property(strong) NSString *failure;
@end
@implementation AuditFunctionResolver
- (void)resetFailureState { self.failure=nil; }
- (BOOL)hadLookupFailure { return self.failure!=nil; }
- (NSString *)firstFailureReason { return self.failure; }
- (id)functionWithFunctionRef:(unsigned long long)ref {
    NSString *key=[NSString stringWithFormat:@"%llu",ref];id function=self.functions[key];
    if(!function)self.failure=[@"unbound function reference " stringByAppendingString:key];
    return function;
}
@end

static NSString *digest(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *s=[NSMutableString new];
    for(unsigned i=0;i<sizeof hash;i++)[s appendFormat:@"%02x",hash[i]];
    return s;
}
static void writeJSON(id value, NSString *path) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path options:NSDataWritingAtomic error:nil];
}
static NSDictionary *computeControl(id<MTLDevice> device) {
    NSError *error=nil;
    id<MTLLibrary> library=[device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; kernel void audit_control(device uint *p [[buffer(0)]], uint i [[thread_position_in_grid]]) { if(i<16) p[i]=i*3+7; }" options:nil error:&error];
    id<MTLFunction> function=[library newFunctionWithName:@"audit_control"];
    if(!function)return @{@"status":@"function_failed",@"error":error.description?:@""};
    id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&error];
    if(!pipeline)return @{@"status":@"pipeline_failed",@"error":error.description?:@""};
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLBuffer> buffer=[device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    if(!queue || !buffer)return @{@"status":@"resource_failed"};
    memset(buffer.contents,0xAA,64);
    id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];[encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(16,1,1) threadsPerThreadgroup:MTLSizeMake(16,1,1)];[encoder endEncoding];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [command addCompletedHandler:^(id<MTLCommandBuffer> c){dispatch_semaphore_signal(done);}];
    [command commit];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)))return @{@"status":@"timeout"};
    NSMutableArray *actual=[NSMutableArray new];BOOL match=command.status==MTLCommandBufferStatusCompleted;
    for(unsigned i=0;i<16;i++){uint32_t v=((uint32_t *)buffer.contents)[i];[actual addObject:@(v)];match&=v==i*3+7;}
    return @{@"status":match?@"exact_match":@"failed",@"actual":actual,@"error":command.error.description?:@""};
}
static NSDictionary *imageControl(id<MTLDevice> device, NSString *path) {
    NSData *data=[NSData dataWithContentsOfFile:path];NSError *error=nil;
    if(!data)return @{@"status":@"missing_resource"};
    CIKernel *kernel=[CIKernel kernelWithFunctionName:@"sampleSource" fromMetalLibraryData:data error:&error];
    NSMutableDictionary *result=[@{@"sha256":digest(data),@"kernel_resolved":@(kernel!=nil),@"error":error.description?:@""} mutableCopy];
    if(!kernel){result[@"status"]=@"kernel_failed";return result;}
    const unsigned char input[16]={255,0,0,255,0,255,0,255,0,0,255,255,255,255,0,255};
    CIImage *image=[CIImage imageWithBitmapData:[NSData dataWithBytes:input length:16] bytesPerRow:8 size:CGSizeMake(2,2) format:kCIFormatRGBA8 colorSpace:nil];
    CGRect extent=CGRectMake(0,0,2,2);
    CIImage *output=[kernel applyWithExtent:extent roiCallback:^CGRect(int index,CGRect rect){return rect;} arguments:@[image]];
    if(!output){result[@"status"]=@"output_failed";return result;}
    CIContext *context=[CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:NSNull.null,kCIContextOutputColorSpace:NSNull.null}];
    unsigned char pixels[16];memset(pixels,0xAA,16);
    [context render:output toBitmap:pixels rowBytes:8 bounds:extent format:kCIFormatRGBA8 colorSpace:nil];
    NSMutableArray *actual=[NSMutableArray new];for(int i=0;i<16;i++)[actual addObject:@(pixels[i])];
    result[@"actual_rgba8"]=actual;result[@"status"]=memcmp(input,pixels,16)?@"pixel_mismatch":@"exact_match";
    return result;
}

static NSDictionary *replayRenderCase(id<MTLDevice> device, NSDictionary *entry, NSDictionary *jobs, NSString *resources) {
    NSMutableDictionary *result=[@{@"sha256":entry[@"sha256"],@"live_state_created":entry[@"state_created"],@"pixel_verified":@NO} mutableCopy];
    NSData *blob=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:entry[@"file"]]];
    if(blob.length<16 || ![digest(blob) isEqual:entry[@"blob_sha256"]?:entry[@"sha256"]]){result[@"status"]=@"invalid_capture_bytes";return result;}
    if([entry[@"schema"] integerValue]==2){
        NSData *bindings=[[NSData alloc] initWithBase64EncodedString:entry[@"bindings_data_base64"] options:0];
        NSDictionary *decoded=bindings?[NSJSONSerialization JSONObjectWithData:bindings options:0 error:nil]:nil;
        NSMutableData *identity=[[digest(blob) stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
        if(bindings)[identity appendData:bindings];
        if(![decoded isEqual:entry[@"function_refs"]] || ![digest(identity) isEqual:entry[@"sha256"]]){result[@"status"]=@"invalid_capture_bindings";return result;}
    }
    uint32_t words[4];memcpy(words,blob.bytes,sizeof words);
    if((words[0]!=0xe && words[0]!=0x33) || words[0]!=[entry[@"tag"] unsignedIntValue] || words[3]>blob.length-16){result[@"status"]=@"invalid_capture_header";return result;}
    NSMutableDictionary *functions=[NSMutableDictionary new];NSMutableArray *bindings=[NSMutableArray new];
    for(NSString *ref in entry[@"function_refs"]){
        NSDictionary *binding=entry[@"function_refs"][ref];NSString *source=[binding[@"library_identity"] componentsSeparatedByString:@":"].firstObject;
        NSDictionary *job=jobs[source];
        if(!job){result[@"status"]=@"missing_library_binding";result[@"missing_source"]=source?:@"unknown";return result;}
        NSData *data=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:job[@"file"]]];
        if(!data || ![digest(data) isEqual:job[@"sha256"]]){result[@"status"]=@"library_hash_failed";return result;}
        NSError *error=nil;dispatch_data_t bytes=dispatch_data_create(data.bytes,data.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        id<MTLLibrary> library=[device newLibraryWithData:bytes error:&error];
        id<MTLFunction> function=[library newFunctionWithName:binding[@"name"]];
        if(!function || function.functionType!=[binding[@"function_type"] unsignedIntegerValue]){result[@"status"]=@"function_binding_failed";result[@"error"]=error.description?:@"";return result;}
        functions[ref]=function;[bindings addObject:@{@"ref":ref,@"source_sha256":source,@"output_sha256":job[@"sha256"],@"name":function.name}];
    }
    if(!functions.count){result[@"status"]=@"no_function_bindings";return result;}
    result[@"bindings"]=bindings;
    AuditFunctionResolver *resolver=[AuditFunctionResolver new];resolver.functions=functions;
    dispatch_data_t data=dispatch_data_create((const uint8_t *)blob.bytes+16,words[3],NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<AuditMetalSerialization> spi=(id)device;NSError *error=nil;id pipeline=nil;
    if(words[0]==0xe){
        SEL selector=@selector(newRenderPipelineDescriptorWithSerializedData:deserializationContext:);
        if(![(id)device respondsToSelector:selector]){result[@"status"]=@"serialization_api_unavailable";return result;}
        MTLRenderPipelineDescriptor *descriptor=[spi newRenderPipelineDescriptorWithSerializedData:data deserializationContext:resolver];
        if(!descriptor || resolver.failure){result[@"status"]=@"descriptor_failed";result[@"error"]=resolver.failure?:@"nil descriptor";return result;}
        result[@"vertex"]=descriptor.vertexFunction.name?:@"";result[@"fragment"]=descriptor.fragmentFunction.name?:@"";
        result[@"samples"]=@(descriptor.rasterSampleCount);result[@"color0"]=@(descriptor.colorAttachments[0].pixelFormat);
        result[@"depth"]=@(descriptor.depthAttachmentPixelFormat);result[@"stencil"]=@(descriptor.stencilAttachmentPixelFormat);
        pipeline=[device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    } else {
        SEL selector=@selector(newTileRenderPipelineDescriptorWithSerializedData:deserializationContext:);
        if(![(id)device respondsToSelector:selector]){result[@"status"]=@"serialization_api_unavailable";return result;}
        MTLTileRenderPipelineDescriptor *descriptor=[spi newTileRenderPipelineDescriptorWithSerializedData:data deserializationContext:resolver];
        if(!descriptor || resolver.failure){result[@"status"]=@"descriptor_failed";result[@"error"]=resolver.failure?:@"nil descriptor";return result;}
        result[@"tile"]=descriptor.tileFunction.name?:@"";
        result[@"samples"]=@(descriptor.rasterSampleCount);result[@"color0"]=@(descriptor.colorAttachments[0].pixelFormat);
        pipeline=[device newRenderPipelineStateWithTileDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
    }
    result[@"status"]=pipeline?@"pipeline_created":@"pipeline_failed";result[@"error"]=error.description?:@"";
    return result;
}

@interface AuditDelegate : UIResponder <UIApplicationDelegate>
@property(strong,nonatomic) UIWindow *window;
@property(strong,nonatomic) UILabel *label;
@end
@implementation AuditDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.systemBackgroundColor;
    self.label=[[UILabel alloc] initWithFrame:vc.view.bounds];self.label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.label.textAlignment=NSTextAlignmentCenter;self.label.numberOfLines=0;self.label.text=@"Henge Shader Audit\nStarting isolated preflight…";
    [vc.view addSubview:self.label];self.window.rootViewController=vc;[self.window makeKeyAndVisible];
    app.idleTimerDisabled=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[self runAudit];});
    return YES;
}
- (void)runAudit { @autoreleasepool {
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *resources=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"AuditData"];
    NSData *manifestData=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:@"jobs.json"]];
    NSDictionary *manifest=manifestData?[NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil]:nil;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    NSMutableDictionary *report=[@{@"schema":@1,@"os":UIDevice.currentDevice.systemVersion,@"device":device.name?:@"none",@"manifest_sha256":manifestData?digest(manifestData):@"",@"status":@"running",@"results":[NSMutableArray new],@"framework_kernels_dispatched":@NO} mutableCopy];
    NSString *output=[documents stringByAppendingPathComponent:@"audit.json"];
    writeJSON(report,output);
    if(!device || !manifest){report[@"status"]=!device?@"no_metal_device":@"invalid_manifest";writeJSON(report,output);dispatch_async(dispatch_get_main_queue(),^{self.label.text=[report[@"status"] description];UIApplication.sharedApplication.idleTimerDisabled=NO;});return;}
    report[@"compute_control"]=computeControl(device);
    report[@"image_control"]=imageControl(device,[resources stringByAppendingPathComponent:@"sampler-control.metallib"]);
    writeJSON(report,output);
    NSUInteger completed=0;NSArray *jobs=manifest[@"jobs"];
    if(manifest[@"run_function_preflight"] && ![manifest[@"run_function_preflight"] boolValue])jobs=@[];
    for(NSDictionary *job in jobs) { @autoreleasepool {
        writeJSON(@{@"source_sha256":job[@"source_sha256"],@"completed":@(completed),@"total":@(jobs.count)},[documents stringByAppendingPathComponent:@"current.json"]);
        NSMutableDictionary *item=[@{@"source_sha256":job[@"source_sha256"],@"provenance":job[@"provenance"],@"functions":[NSMutableArray new],@"pixel_verified":@NO} mutableCopy];
        @try {
            NSData *data=[NSData dataWithContentsOfFile:[resources stringByAppendingPathComponent:job[@"file"]]];
            if(!data || ![digest(data) isEqual:job[@"sha256"]]){item[@"status"]=@"resource_hash_failed";}
            else {
                item[@"sha256"]=digest(data);NSError *error=nil;
                dispatch_data_t bytes=dispatch_data_create(data.bytes,data.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                id<MTLLibrary> library=[device newLibraryWithData:bytes error:&error];
                item[@"status"]=library?@"library_loaded":@"library_failed";item[@"error"]=error.description?:@"";
                if(library){
                    item[@"function_names"]=library.functionNames;
                    for(NSDictionary *expected in job[@"functions"]){
                        NSString *name=expected[@"name"];NSInteger kind=[expected[@"type_raw"] integerValue];
                        NSMutableDictionary *f=[@{@"name":name,@"declared_type":@(kind)} mutableCopy];
                        [item[@"functions"] addObject:f];
                        if(kind<0 || kind>2){f[@"status"]=@"private_role_not_instantiated";continue;}
                        id<MTLFunction> function=[library newFunctionWithName:name];
                        if(!function){f[@"status"]=@"function_failed";continue;}
                        f[@"actual_type"]=@(function.functionType);
                        if(function.functionType!=(NSUInteger)kind+1){f[@"status"]=@"unexpected_function_type";continue;}
                        f[@"status"]=@"function_created";
                        NSMutableArray *required=[NSMutableArray new];
                        for(MTLFunctionConstant *constant in function.functionConstantsDictionary.allValues)if(constant.required)[required addObject:constant.name];
                        f[@"required_constants"]=required;
                        if(required.count){f[@"pipeline_status"]=@"requires_function_constants";continue;}
                        if(function.functionType!=MTLFunctionTypeKernel){f[@"pipeline_status"]=@"requires_render_descriptor";continue;}
                        if([job[@"pipeline_kind"] isEqual:@"tile"]){
                            NSMutableArray *formats=[NSMutableArray new];BOOL allCreated=YES;
                            for(NSNumber *format in @[@(MTLPixelFormatBGRA8Unorm),@(MTLPixelFormatRGBA16Float)]){
                                MTLTileRenderPipelineDescriptor *descriptor=[MTLTileRenderPipelineDescriptor new];
                                descriptor.tileFunction=function;descriptor.rasterSampleCount=1;
                                descriptor.threadgroupSizeMatchesTileSize=YES;
                                descriptor.colorAttachments[0].pixelFormat=format.unsignedIntegerValue;
                                error=nil;
                                id<MTLRenderPipelineState> tile=[device newRenderPipelineStateWithTileDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
                                [formats addObject:@{@"color_format":format,@"created":@(tile!=nil),@"error":error.description?:@""}];
                                allCreated&=tile!=nil;
                            }
                            f[@"tile_formats"]=formats;
                            f[@"pipeline_status"]=allCreated?@"tile_pipeline_created_for_test_formats":@"tile_pipeline_failed_for_test_formats";
                            continue;
                        }
                        error=nil;id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&error];
                        f[@"pipeline_status"]=pipeline?@"compute_pipeline_created":@"compute_pipeline_failed";
                        f[@"pipeline_error"]=error.description?:@"";
                    }
                }
            }
        } @catch(NSException *exception){item[@"status"]=@"exception";item[@"error"]=exception.description;}
        [report[@"results"] addObject:item];completed++;
        writeJSON(report,output);
        dispatch_async(dispatch_get_main_queue(),^{self.label.text=[NSString stringWithFormat:@"Henge Shader Audit\n%lu / %lu libraries\nLoading and pipeline checks\nFramework shaders are not executed",(unsigned long)completed,(unsigned long)jobs.count];});
    }}
    NSMutableDictionary *jobsByHash=[NSMutableDictionary new];for(NSDictionary *job in manifest[@"jobs"])jobsByHash[job[@"source_sha256"]]=job;
    report[@"render_cases"]=[NSMutableArray new];
    for(NSDictionary *entry in manifest[@"render_cases"]){ @autoreleasepool {
        writeJSON(@{@"render_case":entry[@"sha256"]},[documents stringByAppendingPathComponent:@"current.json"]);
        NSDictionary *result;
        @try { result=replayRenderCase(device,entry,jobsByHash,resources); }
        @catch(NSException *exception){result=@{@"sha256":entry[@"sha256"],@"status":@"exception",@"error":exception.description};}
        [report[@"render_cases"] addObject:result];writeJSON(report,output);
    }}
    if([manifest[@"run_image_effects"] boolValue]) {
        extern int runCoreImageAudit(NSString *directory);
        NSString *effects=[documents stringByAppendingPathComponent:@"image-effects"];
        dispatch_async(dispatch_get_main_queue(),^{self.label.text=@"Henge Shader Audit\nRendering native image-effect references…";});
        int status=runCoreImageAudit(effects);
        NSData *data=[NSData dataWithContentsOfFile:[effects stringByAppendingPathComponent:@"results.json"]];
        NSDictionary *result=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        report[@"image_effects"]=@{@"exit_code":@(status),@"report":result?:@{}};
    }
    report[@"status"]=@"complete";writeJSON(report,output);
    dispatch_async(dispatch_get_main_queue(),^{self.label.text=@"Henge Shader Audit\nPreflight complete\nResults saved for review";UIApplication.sharedApplication.idleTimerDisabled=NO;});
} }
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AuditDelegate.class)); } }
