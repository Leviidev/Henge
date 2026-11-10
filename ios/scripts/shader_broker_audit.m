/* Authored first-use compute/render oracle using Henge's production broker.
 * Run once with a live companion and again with it disconnected. Resources are
 * newly compiled macOS MTLBs, not preconverted iOS libraries. */
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include "pvg_shader_broker.h"

static void save(NSDictionary *value, NSString *root) {
    [[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[root stringByAppendingPathComponent:@"broker-audit.json"] options:NSDataWritingAtomic error:nil];
}

static id<MTLFunction> load(id<MTLDevice> device, NSDictionary *job, NSString *root,
                          NSMutableArray *observations) {
    NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:
                      [@"AuditData/" stringByAppendingString:job[@"file"]]];
    NSData *original = [NSData dataWithContentsOfFile:path];
    NSString *source = hv_shader_digest(original);
    if (![source isEqual:job[@"sha256"]]) return nil;
    [original writeToFile:[root stringByAppendingPathComponent:
        [NSString stringWithFormat:@"sonoma-guestlib-%@.metallib", source]] options:NSDataWritingAtomic error:nil];
    NSError *error = nil;
    dispatch_data_t initial = dispatch_data_create(original.bytes, original.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> mac = [device newLibraryWithData:initial error:&error];
    NSMutableDictionary *result = [@{@"source_sha256":source, @"function":job[@"function"],
        @"original_loaded":@(mac != nil), @"original_error":error.description ?: @""} mutableCopy];
    NSDictionary *config = hv_shader_json([root stringByAppendingPathComponent:@"shader-compiler-config.json"]);
    NSString *recipe = config[@"recipe"];
    result[@"cached_before"] = @(hv_shader_digest_valid(recipe) && hv_shader_cache(root, source, recipe) != nil);
    result[@"companion_live"] = @(recipe && hv_shader_lease(root, recipe) != nil);
    double start = NSProcessInfo.processInfo.systemUptime;
    NSData *converted = hv_shader_converted_bytes(root, source, job[@"function"]);
    result[@"seconds"] = @(NSProcessInfo.processInfo.systemUptime-start);
    result[@"recipe"] = recipe ?: @"";
    result[@"output_sha256"] = converted ? hv_shader_digest(converted) : @"";
    id<MTLFunction> function = nil;
    if (converted) {
        dispatch_data_t data = dispatch_data_create(converted.bytes, converted.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
        function = [library newFunctionWithName:job[@"function"]];
    }
    result[@"converted_function_loaded"] = @(function != nil);
    result[@"error"] = function ? @"" : error.description ?: @"no conversion";
    [observations addObject:result];
    return function;
}

static NSDictionary *runBrokerAudit(NSString *root) {
    NSString *manifestPath = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"AuditData/broker-jobs.json"];
    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
    NSDictionary *jobs = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    NSMutableDictionary *report = [@{@"status":@"running", @"manifest_sha256":hv_shader_digest(manifestData)} mutableCopy];
    NSMutableArray *loads = [NSMutableArray new];
    report[@"libraries"] = loads;
    save(report, root);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLFunction> compute = load(device, jobs[@"compute"], root, loads);
    id<MTLFunction> vertex = load(device, jobs[@"vertex"], root, loads);
    id<MTLFunction> fragment = load(device, jobs[@"fragment"], root, loads);
    save(report, root);
    if (!compute || !vertex || !fragment) { report[@"status"] = @"function_failed"; return report; }
    NSError *error = nil;
    id<MTLComputePipelineState> cp = [device newComputePipelineStateWithFunction:compute error:&error];
    MTLRenderPipelineDescriptor *rp = [MTLRenderPipelineDescriptor new];
    rp.vertexFunction = vertex; rp.fragmentFunction = fragment;
    rp.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> render = [device newRenderPipelineStateWithDescriptor:rp error:&error];
    if (!cp || !render) { report[@"status"] = @"pipeline_failed"; report[@"error"] = error.description ?: @""; return report; }
    id<MTLBuffer> buffer = [device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    memset(buffer.contents, 0xAA, 64);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:cp]; [encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(16,1,1) threadsPerThreadgroup:MTLSizeMake(16,1,1)];
    [encoder endEncoding];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(1,0,1,1);
    id<MTLRenderCommandEncoder> re = [command renderCommandEncoderWithDescriptor:pass];
    [re setRenderPipelineState:render]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [command addCompletedHandler:^(id<MTLCommandBuffer> c){ dispatch_semaphore_signal(done); }];
    [command commit];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC))) {
        report[@"status"] = @"gpu_timeout"; return report;
    }
    BOOL match = command.status == MTLCommandBufferStatusCompleted;
    NSMutableArray *actual = [NSMutableArray new];
    for (unsigned i=0; i<16; i++) {
        uint32_t value = ((uint32_t *)buffer.contents)[i];
        [actual addObject:@(value)]; match &= value == i*13 + [jobs[@"nonce"] unsignedIntValue];
    }
    report[@"compute_actual"] = actual;
    uint8_t pixels[64]; memset(pixels,0xAA,sizeof pixels);
    [texture getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
    NSMutableArray *rgba = [NSMutableArray new];
    for (int i=0; i<64; i++) { [rgba addObject:@(pixels[i])]; match &= pixels[i] == [jobs[@"rgba"][i%4] unsignedIntValue]; }
    report[@"render_actual_rgba8"] = rgba;
    report[@"status"] = match ? @"exact_match" : @"output_mismatch";
    report[@"command_error"] = command.error.description ?: @"";
    return report;
}

@interface BrokerAuditDelegate : UIResponder <UIApplicationDelegate>
@property(strong) UIWindow *window;
@end
@implementation BrokerAuditDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *view = [UIViewController new];
    view.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(40,100,1100,400)];
    label.numberOfLines = 0; label.text = @"Testing first-use shader compilation…";
    [view.view addSubview:label]; self.window.rootViewController = view; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSString *root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSDictionary *report = runBrokerAudit(root); save(report, root);
        dispatch_async(dispatch_get_main_queue(), ^{ label.text = [NSString stringWithFormat:@"Shader broker audit: %@", report[@"status"]]; });
    });
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(BrokerAuditDelegate.class)); }
}
