#import <Foundation/Foundation.h>
#include "../devices/metal4_encoder.h"
#include <assert.h>
/* Execute the production descriptor/encoder adapter even when the runner's
   Paravirtual GPU cannot execute Metal4. GPU pixel proof stays separate. */
@interface PlanEncoder : NSObject
@property unsigned ends,draws;
@end
@implementation PlanEncoder
- (void)setArgumentTable:(id)t atStages:(MTLRenderStages)s {assert([t isKindOfClass:NSClassFromString(@"PlanArgumentTable")]);(void)s;}
- (void)barrierAfterQueueStages:(MTLStages)a beforeStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)o {(void)a;(void)b;(void)o;}
- (void)barrierAfterStages:(MTLStages)a beforeQueueStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)o {(void)a;(void)b;(void)o;}
- (void)endEncoding {self.ends++;}
- (void)drawPrimitives:(MTLPrimitiveType)t indirectBuffer:(MTLGPUAddress)a {(void)t;assert(a==0x12340008);self.draws++;}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)t indexType:(MTLIndexType)i indexBuffer:(MTLGPUAddress)a indexBufferLength:(NSUInteger)n indirectBuffer:(MTLGPUAddress)b {(void)t;(void)i;assert(a==0x12340004&&n==252&&b==0x12340008);self.draws++;}
@end
@interface PlanBuffer : NSObject
@property(nonatomic,strong) PlanEncoder *encoder;
@property(nonatomic,strong) MTL4RenderPassDescriptor *pass;
@end
@implementation PlanBuffer
- (id)renderCommandEncoderWithDescriptor:(MTL4RenderPassDescriptor *)d {self.pass=d;self.encoder=[PlanEncoder new];return self.encoder;}
@end
@interface PlanArgumentTable : NSObject
@end
@implementation PlanArgumentTable
- (void)setAddress:(MTLGPUAddress)a atIndex:(NSUInteger)i {(void)a;(void)i;}
- (void)setAddress:(MTLGPUAddress)a attributeStride:(NSUInteger)s atIndex:(NSUInteger)i {(void)a;(void)s;(void)i;}
- (void)setTexture:(MTLResourceID)t atIndex:(NSUInteger)i {(void)t;(void)i;}
- (void)setSamplerState:(MTLResourceID)t atIndex:(NSUInteger)i {(void)t;(void)i;}
@end
@interface PlanRuntime : NSObject
@end
@implementation PlanRuntime
- (id)table:(id)job {(void)job;return [[HvMetal4Arguments alloc]initWithTable:(id)[PlanArgumentTable new]];}
- (void)retainResource:(id)resource job:(id)job {(void)resource;(void)job;}
@end
@interface PlanArguments : NSObject
@end
@implementation PlanArguments
- (NSUInteger)length {return 256;}
- (MTLGPUAddress)gpuAddress {return 0x12340000;}
@end
@interface PlanCapableDevice : NSObject
@end
@implementation PlanCapableDevice
- (BOOL)supportsFamily:(MTLGPUFamily)family {return family==MTLGPUFamilyMetal4;}
@end
@interface PlanLibrary : NSObject
@end
@implementation PlanLibrary
- (id)device {return [PlanCapableDevice new];}
@end
@interface PlanFunction : NSObject
@end
@implementation PlanFunction
- (NSString *)name {return @"declared_defaults";}
- (NSDictionary *)functionConstantsDictionary {return @{@"optional":@1};}
- (MTLPatchType)patchType {return MTLPatchTypeNone;}
@end
@interface PlanPipelineSource : NSProxy {
@public id descriptor,function;
}
@end
@implementation PlanPipelineSource
- (id)vertexFunction {return function;}
- (id)computeFunction {return function;}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {return [descriptor methodSignatureForSelector:selector];}
- (void)forwardInvocation:(NSInvocation *)call {[call invokeWithTarget:descriptor];}
@end
static NSData *segment(unsigned info,NSArray<NSData *> *records,BOOL inclusive) {
    NSMutableData *d=[NSMutableData dataWithLength:8];for(NSData *r in records)[d appendData:r];
    uint32_t header[]={(uint32_t)(d.length-(inclusive?0:8)),info};memcpy(d.mutableBytes,header,8);return d;
}
static NSData *record(unsigned tag,const void *p,size_t n) {
    uint32_t h[]={tag,(uint32_t)n+8};NSMutableData *d=[NSMutableData dataWithBytes:h length:8];
    [d appendBytes:p length:n];return d;
}
int main(void){@autoreleasepool {
    uint8_t pass[76]={0};uint32_t colorOn[]={1,0,2},colorOff[]={0,0,2};uint64_t on=1,off=0;
    uint8_t query[20]={0};HvGpuReject why={0};
    NSArray *commands=@[
        segment(0x10000,@[record(26,pass,sizeof pass),record(103,colorOn,sizeof colorOn)],YES),
        segment(0x10104,@[record(460,query,sizeof query)],NO),
        segment(0x100,@[record(103,colorOff,sizeof colorOff),record(106,&on,8),record(121,&off,8)],NO)
    ];
    HvMetal4Plan *plan=hv_metal4_plan_commands(commands,&why);
    assert(plan&&plan.graphics&&plan.options.length==sizeof(HvGpuPassOptions));
    HvGpuPassOptions options;memcpy(&options,plan.options.bytes,sizeof options);
    assert(options.mask==((1u<<2)|(1u<<8)|(1u<<9)));
    assert(!options.values[2]&&options.values[8]==1&&!options.values[9]); /* final setter wins */
    HvMetal4Plan *metadata=hv_metal4_plan_commands(@[commands[1]],&why);
    assert(metadata&&!metadata.graphics&&!metadata.options.length);
    uint32_t value=0;
    /* The reference decoder consumes 219 without an encoder operation. It
       must not split adjacent supported compute units into different queues. */
    NSData *computeCommands=segment(1,@[record(214,&value,0),record(219,&value,4)],NO);
    HvMetal4Plan *computePlan=hv_metal4_plan_commands(@[computeCommands],&why);
    assert(computePlan&&computePlan.graphics&&!computePlan.options.length);
    NSArray<HvMetal4Run *> *computeRuns=hv_metal4_command_runs(@[computeCommands,computeCommands]);
    assert(computeRuns.count==1&&computeRuns[0]->plan&&computeRuns[0]->commands.count==2);
    assert(!hv_metal4_plan_commands(@[segment(1,@[record(219,&value,3)],NO)],&why));
    assert(why.reason==HV_GPU_PAYLOAD&&why.tag==219);
    assert(!hv_metal4_plan_commands(@[segment(0,@[record(13,&value,4)],NO)],&why));
    assert(why.reason==HV_GPU_TAG&&why.type==0&&why.tag==13);
    uint32_t bad[]={1,0,8};
    assert(!hv_metal4_plan_commands(@[segment(0,@[record(103,bad,sizeof bad)],NO)],&why));
    assert(why.reason==HV_GPU_PAYLOAD&&why.tag==103);
    NSArray *two=@[commands[0],commands[2],segment(0,@[record(26,pass,sizeof pass),record(106,&off,8)],NO)];
    HvMetal4Plan *twoplan=hv_metal4_plan_commands(two,&why);
    assert(twoplan&&twoplan.options.length==2*sizeof(HvGpuPassOptions));
    NSData *opaque=segment(0,@[record(13,&value,4)],NO);
    NSArray<HvMetal4Run *> *runs=hv_metal4_command_runs(@[commands[0],commands[1],commands[2],opaque,commands[0],commands[2]]);
    assert(runs.count==3&&runs[0]->plan&&!runs[1]->plan&&runs[2]->plan);
    assert(runs[0]->commands.count==3&&runs[1]->commands.count==1&&runs[2]->commands.count==2);
    assert(runs[1]->rejection.tag==13);
    NSArray<HvMetal4Run *> *merged=hv_metal4_command_runs(@[commands[0],commands[2],commands[0],commands[2]]);
    assert(merged.count==1&&merged[0]->commands.count==4&&merged[0]->plan.options.length==2*sizeof(HvGpuPassOptions));
    PlanBuffer *buffer=[PlanBuffer new];HvMetal4Job *job=[HvMetal4Job new];job->buffer=(id)buffer;
    HvMetal4Buffer *bridge=[HvMetal4Buffer new];bridge->job=job;bridge->runtime=(id)[PlanRuntime new];bridge->passOptions=plan.options;
    HvMetal4Encoder *e=[bridge renderCommandEncoderWithDescriptor:[MTLRenderPassDescriptor renderPassDescriptor]];
    assert(buffer.pass.depthAttachment.storeActionOptions==1&&buffer.pass.colorAttachments[2].storeActionOptions==0);
    [e setColorStoreActionOptions:1 atIndex:2];[e setColorStoreActionOptions:0 atIndex:2];
    [e setDepthStoreActionOptions:1];[e setStencilStoreActionOptions:0];
    id args=[PlanArguments new];
    [e drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:args indirectBufferOffset:8];
    [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt16 indexBuffer:args indexBufferOffset:4 indirectBuffer:args indirectBufferOffset:8];
    assert(buffer.encoder.draws==2);
    BOOL invalid=NO;@try{[e drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:args indirectBufferOffset:252];}@catch(NSException *x){(void)x;invalid=YES;}assert(invalid);
    [e endEncoding];[e abortEncoding];assert(buffer.encoder.ends==1);
    bridge->passIndex=0;
    e=[bridge renderCommandEncoderWithDescriptor:[MTLRenderPassDescriptor renderPassDescriptor]];
    invalid=NO;@try{[e endEncoding];}@catch(NSException *x){(void)x;invalid=YES;}
    assert(invalid);[e abortEncoding];assert(buffer.encoder.ends==1);
    id fn=[PlanFunction new],library=[PlanLibrary new];hv_metal4_note_function(fn,library);
    assert(objc_getAssociatedObject(fn,"henge.metal4.function"));
    PlanPipelineSource *render=[PlanPipelineSource alloc];render->function=fn;render->descriptor=[MTLRenderPipelineDescriptor new];
    MTL4RenderPipelineDescriptor *depthOnly=hv_metal4_descriptor(14,render);
    assert(depthOnly&&depthOnly.vertexFunctionDescriptor&&!depthOnly.fragmentFunctionDescriptor&&depthOnly.rasterizationEnabled);
    PlanPipelineSource *compute=[PlanPipelineSource alloc];compute->function=fn;
    MTLComputePipelineDescriptor *old=[MTLComputePipelineDescriptor new];compute->descriptor=old;
    assert(hv_metal4_descriptor(11,compute));
    old.stageInputDescriptor=[MTLStageInputOutputDescriptor stageInputOutputDescriptor];old.stageInputDescriptor.layouts[0].stride=4;
    assert(hv_metal4_descriptor(11,compute)); /* unused layout hints need no fallback */
    old.stageInputDescriptor.attributes[0].format=MTLAttributeFormatFloat;
    assert(!hv_metal4_descriptor(11,compute));
    puts("PASS Metal4 descriptor mapping: unspecialized declared defaults, depth-only render and explicit legacy stage-input rejection");
    puts("PASS Metal4 pass plans: mixed render/query continuation, final store options, separate metadata, multi-pass and rejection attribution");
    return 0;
}}
