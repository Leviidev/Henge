#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2)return 64;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfFile:@(argv[1])];
    dispatch_data_t bytes=dispatch_data_create(data.bytes,data.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> lib=[device newLibraryWithData:bytes error:&error];
    NSMutableDictionary *result=[@{@"device":device.name?:@"none",@"library_loaded":@(lib!=nil),@"load_error":error.description?:@"",@"functions":lib.functionNames?:@[]} mutableCopy];
    NSMutableArray *cases=[NSMutableArray array];BOOL passed=lib!=nil;
    for(NSString *name in @[@"alpha",@"beta"]) for(int mode=0;mode<2;mode++) {
        if(!lib)continue;
        BOOL flag=mode;MTLFunctionConstantValues *values=[MTLFunctionConstantValues new];
        [values setConstantValue:&flag type:MTLDataTypeBool atIndex:0];error=nil;
        id<MTLFunction> fn=[lib newFunctionWithName:name constantValues:values error:&error];
        NSMutableDictionary *row=[@{@"name":name,@"mode":@(mode),@"function_created":@(fn!=nil),@"function_error":error.description?:@""} mutableCopy];
        error=nil;id<MTLComputePipelineState> pipeline=fn?[device newComputePipelineStateWithFunction:fn error:&error]:nil;
        row[@"pipeline_created"]=@(pipeline!=nil);row[@"pipeline_error"]=error.description?:@"";
        if(pipeline){
            const int count=256;id<MTLBuffer> buffer=[device newBufferWithLength:count*sizeof(uint32_t) options:MTLResourceStorageModeShared];
            memset(buffer.contents,0xAA,buffer.length);id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> command=[queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];[encoder setComputePipelineState:pipeline];[encoder setBuffer:buffer offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(64,pipeline.maxTotalThreadsPerThreadgroup),1,1)];[encoder endEncoding];[command commit];[command waitUntilCompleted];
            unsigned mismatches=0;uint32_t *actual=buffer.contents;unsigned base=[name isEqualToString:@"alpha"]?1000:2000;
            for(int i=0;i<count;i++)if(actual[i]!=(base+100*mode+i))mismatches++;
            BOOL exact=command.status==MTLCommandBufferStatusCompleted && mismatches==0;
            row[@"dispatch_completed"]=@(command.status==MTLCommandBufferStatusCompleted);row[@"command_error"]=command.error.description?:@"";
            row[@"elements_checked"]=@(count);row[@"mismatches"]=@(mismatches);row[@"readback_exact"]=@(exact);passed &= exact;
        }else passed=NO;
        [cases addObject:row];
    }
    result[@"cases"]=cases;result[@"passed"]=@(passed);NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);putchar('\n');return passed?0:1;
} }
