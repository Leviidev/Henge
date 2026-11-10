/* Authored consumer of two unspecialized functions in the full 150-module archive.
 * Reuses only the already reviewed draw/readback mechanics; no historical draw claim. */
#define main historical_main
#include "shader_inventory_device_historical_render.m"
#undef main
static id<MTLFunction> Specialize(id<MTLLibrary>lib, NSDictionary*spec, NSError**error){
    MTLFunctionConstantValues*v=[MTLFunctionConstantValues new];
    for(NSDictionary*c in spec[@"specialized_constants"]){
        NSString*t=c[@"type"];uint8_t data[4]={0};MTLDataType type;
        if([t isEqual:@"bool"])type=MTLDataTypeBool;
        else if([t isEqual:@"uchar"])type=MTLDataTypeUChar;
        else if([t isEqual:@"uchar4"])type=MTLDataTypeUChar4;
        else return nil;
        if(type==MTLDataTypeUChar4)for(int i=0;i<4;i++)data[i]=[c[@"value"][i]unsignedCharValue];else data[0]=[c[@"value"]unsignedCharValue];
        [v setConstantValue:data type:type atIndex:[c[@"index"]unsignedIntegerValue]];
    }
    return [lib newFunctionWithName:spec[@"function"] constantValues:v error:error];
}
static NSDictionary* RunQuartz(NSString*assets,NSString*output){@autoreleasepool{
    ReportRoot=output;atomic_store(&Done,false);dispatch_after(dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{if(!atomic_load(&Done)){Save(@{@"status":@"watchdog_timeout"},@"quartzcore-timeout.json");_exit(124);}});[NSFileManager.defaultManager createDirectoryAtPath:ReportRoot withIntermediateDirectories:YES attributes:nil error:nil];NSData*manifest=[NSData dataWithContentsOfFile:[assets stringByAppendingPathComponent:@"quartzcore-jobs.json"]];NSDictionary*m=[NSJSONSerialization JSONObjectWithData:manifest options:0 error:nil];NSMutableDictionary*r=[@{@"manifest_sha256":Hash(manifest),@"scope":@"full archive, specialized shipped base functions, authored descriptor and resources",@"cases":[NSMutableArray new],@"exact_historical_descriptor_verified":@NO}mutableCopy];
    @try{id<MTLDevice>dev=MTLCreateSystemDefaultDevice();r[@"device"]=dev.name?:@"none";NSError*e=nil;id<MTLLibrary>lib=Load(dev,assets,m[@"library"],&e);r[@"library_loaded"]=@(lib!=nil);r[@"library_error"]=e.description?:@"";r[@"library_function_count"]=@(lib.functionNames.count);e=nil;id<MTLFunction>vf=Specialize(lib,m[@"vertex"],&e);r[@"vertex_error"]=e.description?:@"";e=nil;id<MTLFunction>ff=Specialize(lib,m[@"fragment"],&e);r[@"fragment_error"]=e.description?:@"";r[@"vertex_specialized"]=@(vf!=nil);r[@"fragment_specialized"]=@(ff!=nil);
        if(vf&&ff){MTLRenderPipelineDescriptor*d=[MTLRenderPipelineDescriptor new];d.vertexFunction=vf;d.fragmentFunction=ff;d.rasterSampleCount=1;d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;d.colorAttachments[0].blendingEnabled=NO;MTLVertexDescriptor*v=[MTLVertexDescriptor new];v.attributes[0].format=MTLVertexFormatFloat4;v.attributes[0].offset=0;v.attributes[0].bufferIndex=1;v.attributes[3].format=MTLVertexFormatHalf4;v.attributes[3].offset=32;v.attributes[3].bufferIndex=1;v.layouts[1].stride=48;v.layouts[1].stepFunction=MTLVertexStepFunctionPerVertex;d.vertexDescriptor=v;e=nil;id<MTLRenderPipelineState>p=[dev newRenderPipelineStateWithDescriptor:d error:&e];r[@"pipeline_created"]=@(p!=nil);r[@"pipeline_error"]=e.description?:@"";r[@"descriptor"]=@{@"color0":@80,@"samples":@1,@"vertex_buffer":@1,@"stride":@48,@"position_attribute":@0,@"position_offset":@0,@"color_attribute":@3,@"color_offset":@32,@"hardware_blending":@NO};if(p)for(NSDictionary*c in m[@"cases"])[r[@"cases"]addObject:Render(dev,p,c)];}
        r[@"status"]=@"completed_requires_review";
    }@catch(NSException*e){r[@"status"]=@"exception";r[@"exception"]=e.description;}Save(r,@"quartzcore-report.json");atomic_store(&Done,true);return r;
}}

#if TARGET_OS_IOS
@interface QuartzDelegate:UIResponder<UIApplicationDelegate>
@property(strong,nonatomic)UIWindow*window;
@end
@implementation QuartzDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options{
    self.window=[[UIWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];UIViewController*vc=[UIViewController new];vc.view.backgroundColor=UIColor.systemBackgroundColor;UILabel*l=[[UILabel alloc]initWithFrame:vc.view.bounds];l.numberOfLines=0;l.textAlignment=NSTextAlignmentCenter;l.text=@"QuartzCore 150-module library\nAuthored framebuffer-fetch oracle";[vc.view addSubview:l];self.window.rootViewController=vc;[self.window makeKeyAndVisible];app.idleTimerDisabled=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString*base=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"quartzcore-150-01"];[NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];NSString*uid=NSUUID.UUID.UUIDString;NSData*latest=[NSJSONSerialization dataWithJSONObject:@{@"run_id":uid,@"relative_directory":uid} options:0 error:nil];[latest writeToFile:[base stringByAppendingPathComponent:@"quartzcore-latest.json"] atomically:YES];NSDictionary*r=RunQuartz([NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"AuditAssets"],[base stringByAppendingPathComponent:uid]);dispatch_async(dispatch_get_main_queue(),^{l.text=[NSString stringWithFormat:@"QuartzCore archive\n%@\nAuthored consumer only",r[@"status"]];app.idleTimerDisabled=NO;});});return YES;
}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(QuartzDelegate.class));}}
#else
int main(int argc,const char**argv){@autoreleasepool{if(argc!=3)return 64;NSApplicationLoad();NSDictionary*r=RunQuartz(@(argv[1]),@(argv[2]));return[r[@"pipeline_created"]boolValue]?0:1;}}
#endif
