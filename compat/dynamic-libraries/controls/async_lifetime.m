#define main HGMatrixMain
#include "path_runner.m"
#undef main
static BOOL Wait(dispatch_semaphore_t sem){return dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_SEC))==0;}
int main(int argc,char**argv){@autoreleasepool{if(argc!=2)return 64;NSApplicationLoad();NSString*out=[NSURL fileURLWithPath:@(argv[1])].path;ReportRoot=out;[[NSFileManager defaultManager]createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];id<MTLDevice>d=MTLCreateSystemDefaultDevice();NSMutableDictionary*r=[NSMutableDictionary new];__block id<MTLLibrary>shared=nil,consumer=nil;__block NSError*err=nil;__block unsigned sourceCallbacks=0,pipelineCallbacks=0;dispatch_semaphore_t sem=dispatch_semaphore_create(0);
MTLCompileOptions*o=[MTLCompileOptions new];o.libraryType=MTLLibraryTypeDynamic;o.installName=[out stringByAppendingPathComponent:@"dynamic.metallib"];
[d newLibraryWithSource:@"extern \"C\" uint inventory_transform(uint x){return x*7+19;}" options:o completionHandler:^(id<MTLLibrary>l,NSError*e){shared=l;err=e;sourceCallbacks++;dispatch_semaphore_signal(sem);}];if(!Wait(sem)||!shared)return 2;
id<MTLDynamicLibrary>dynamic=[d newDynamicLibrary:shared error:&err];if(!dynamic||![dynamic serializeToURL:[NSURL fileURLWithPath:o.installName]error:&err])return 3;__weak id weakDynamic=dynamic;
@autoreleasepool{o=[MTLCompileOptions new];o.libraries=@[dynamic];NSString*source=@"#include <metal_stdlib>\nusing namespace metal; extern \"C\" uint inventory_transform(uint); kernel void dynamic_consumer(device uint*out [[buffer(0)]],uint i [[thread_position_in_grid]]){out[i]=inventory_transform(i);}";
[d newLibraryWithSource:source options:o completionHandler:^(id<MTLLibrary>l,NSError*e){consumer=l;err=e;sourceCallbacks++;dispatch_semaphore_signal(sem);}];dynamic=nil;shared=nil;o=nil;}if(!Wait(sem)||!consumer)return 4;
__block id<MTLComputePipelineState>pipeline=nil;__weak id weakFunction=nil,weakConsumer=consumer;
@autoreleasepool{MTLComputePipelineDescriptor*desc=[MTLComputePipelineDescriptor new];id<MTLFunction>f=[consumer newFunctionWithName:@"dynamic_consumer"];weakFunction=f;desc.computeFunction=f;
[d newComputePipelineStateWithDescriptor:desc options:MTLPipelineOptionNone completionHandler:^(id<MTLComputePipelineState>p,MTLComputePipelineReflection*reflection,NSError*e){pipeline=p;err=e;pipelineCallbacks++;dispatch_semaphore_signal(sem);}];consumer=nil;f=nil;desc=nil;}
if(!Wait(sem)||!pipeline){r[@"pipeline_error"]=err.description?:@"timeout";goto finish;}
r[@"execution"]=DispatchOracle(d,pipeline,0,7,19);r[@"source_callbacks"]=@(sourceCallbacks);r[@"pipeline_callbacks"]=@(pipelineCallbacks);
// Drain the callback's autorelease pool without owning dependency objects.
[NSThread sleepForTimeInterval:.1];r[@"library_alive_after_callback"]=@(weakConsumer!=nil);r[@"function_alive_after_callback"]=@(weakFunction!=nil);r[@"dynamic_alive_after_callback"]=@(weakDynamic!=nil);r[@"supports_render_dynamic"]=@(d.supportsRenderDynamicLibraries);
finish:;
NSData*j=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil];[j writeToFile:[out stringByAppendingPathComponent:@"async-report.json"]atomically:YES];fwrite(j.bytes,1,j.length,stdout);return [r[@"execution"][@"readback_exact"]boolValue]&&sourceCallbacks==2&&pipelineCallbacks==1&&!weakConsumer&&!weakFunction&&!weakDynamic?0:1;}}
