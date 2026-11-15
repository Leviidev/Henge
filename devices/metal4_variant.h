#pragma once
#include "metal4_runtime.h"
#include "metal4_pipeline.h"
#include <objc/runtime.h>

enum { HV_M4_PIPELINE_IDLE,HV_M4_PIPELINE_QUEUED,HV_M4_PIPELINE_READY,HV_M4_PIPELINE_REJECTED };
API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvMetal4Variant : NSObject {
@public
    _Atomic int phase;
    unsigned tag;
    id descriptor,pipeline;
    NSString *reason;
    dispatch_group_t finished;
}
@end
@implementation HvMetal4Variant
- (instancetype)init {
    if(!(self=[super init]))return nil;
    finished=dispatch_group_create();return self;
}
@end

/* Metadata is published once through an atomic association. A ready/rejected
   result is immutable; acquire/release on phase protects its object lifetime.
   The compilation block retains the old state through the compute ABI check. */
static HvMetal4Variant *hv_metal4_prepare(HvMetal4Runtime *runtime,id state) API_AVAILABLE(macos(26.0),ios(26.0));
static HvMetal4Variant *hv_metal4_prepare(HvMetal4Runtime *runtime,id state) {
    if(!state)return nil;
    HvMetal4Variant *entry=objc_getAssociatedObject(state,"henge.metal4.variant");
    if(!entry)@synchronized(state){
        entry=objc_getAssociatedObject(state,"henge.metal4.variant");
        if(!entry){
            entry=[HvMetal4Variant new];
            NSDictionary *source=objc_getAssociatedObject(state,"henge.metal4.source");
            entry->tag=[source[@"tag"]unsignedIntValue];
            NSString *why=nil;
            entry->descriptor=source?hv_metal4_descriptor_checked(entry->tag,source[@"descriptor"],&why):nil;
            if(!entry->descriptor){entry->reason=why?:@"source descriptor unavailable";atomic_store(&entry->phase,HV_M4_PIPELINE_REJECTED);}
            objc_setAssociatedObject(state,"henge.metal4.source",nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(state,"henge.metal4.variant",entry,OBJC_ASSOCIATION_RETAIN);
        }
    }
    if(atomic_load(&entry->phase)!=HV_M4_PIPELINE_IDLE)return entry;
    int expected=HV_M4_PIPELINE_IDLE;
    if(atomic_compare_exchange_strong(&entry->phase,&expected,HV_M4_PIPELINE_QUEUED)) {
        dispatch_group_enter(entry->finished);
        BOOL queued=[runtime->pipelineQueue enqueue:^(BOOL allowed){
            if(!allowed){atomic_store(&entry->phase,HV_M4_PIPELINE_IDLE);dispatch_group_leave(entry->finished);return;}
            id variant=nil;NSString *why=nil;
            @try {
                variant=[runtime pipeline:entry->descriptor tag:entry->tag bundle:nil];
                if(!variant)why=@"Metal4 pipeline compilation failed";
                if(entry->tag==0xb&&variant){
                    id<MTLComputePipelineState> old=state,new=variant;
                    if(new.threadExecutionWidth!=old.threadExecutionWidth||new.maxTotalThreadsPerThreadgroup<old.maxTotalThreadsPerThreadgroup||new.staticThreadgroupMemoryLength!=old.staticThreadgroupMemoryLength){variant=nil;why=@"compute threadgroup ABI differs from the classic pipeline";}
                }
            }@catch(NSException *exception){variant=nil;why=exception.reason?:@"Metal4 compiler exception";}
            entry->pipeline=variant;entry->reason=why;entry->descriptor=nil;
            atomic_store(&entry->phase,variant?HV_M4_PIPELINE_READY:HV_M4_PIPELINE_REJECTED);
            dispatch_group_leave(entry->finished);
        }];
        if(!queued){atomic_store(&entry->phase,HV_M4_PIPELINE_IDLE);dispatch_group_leave(entry->finished);}
    }
    return entry;
}
static id hv_metal4_variant(HvMetal4Runtime *runtime,id state) API_AVAILABLE(macos(26.0),ios(26.0));
static id hv_metal4_variant(HvMetal4Runtime *runtime,id state) {
    HvMetal4Variant *entry=hv_metal4_prepare(runtime,state);
    return entry&&atomic_load(&entry->phase)==HV_M4_PIPELINE_READY?entry->pipeline:nil;
}
static void hv_metal4_pipeline_fallback(id state) API_AVAILABLE(macos(26.0),ios(26.0));
static void hv_metal4_pipeline_fallback(id state) {
    HvMetal4Variant *entry=objc_getAssociatedObject(state,"henge.metal4.variant");
    if(entry&&atomic_load(&entry->phase)!=HV_M4_PIPELINE_REJECTED)
        [NSException raise:@"HengeMetal4Warming" format:@"optional pipeline warming; original classic pipeline retained"];
    [NSException raise:@"HengeMetal4Fallback" format:@"pipeline: %@",entry?entry->reason:@"source descriptor unavailable"];
}
