#pragma once
/* Supported Metal 4 submission, shared by guest replay and native presentation.
 * Classic/Metal4 queues are joined with a shared event in BOTH directions.
 * The caller's submission lock also guards every classic queue commit. */
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <math.h>
#include <time.h>
#include "pipeline_bundle.h"
#include "metal4_arguments.h"
#include "metal4_compile_queue.h"

API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvMetal4Job : NSObject {
@public
    id<MTL4CommandBuffer> buffer;
    id<MTL4CommandAllocator> allocator;
    id<MTLResidencySet> residency;
    id<MTLBuffer> uniforms;
    NSMutableSet *keep;
    NSMutableSet *allocations;
    NSMutableArray<HvMetal4Arguments *> *tables;
    NSUInteger nextTable;
    uint64_t bridgeOutput;
    NSMutableOrderedSet<id<MTLFence>> *fenceWaits,*fenceUpdates;
}
@end
@implementation HvMetal4Job
@end

API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvMetal4Runtime : NSObject {
    id<MTLDevice> _device;
    id<MTL4CommandQueue> _queue;
    id<MTL4Compiler> _compiler;
    id<MTLSharedEvent> _bridge;
    uint64_t _bridgeValue;
    os_unfair_lock _poolLock;
    NSMutableArray<HvMetal4Job *> *_pool;
    NSUInteger _created;
    _Atomic bool _retainIdleResources;
    NSLock *_compileLock;
    dispatch_queue_t _archiveQueue;
    id<MTL4PipelineDataSetSerializer> _capture;
    NSURL *_cacheDirectory;
    NSArray<id<MTL4Archive>> *_archives;
    BOOL _cacheAdmission,_saveScheduled,_urgentSaveScheduled;
    NSUInteger _pendingPipelines;
@public
    HvMetal4CompileQueue *pipelineQueue;
    _Atomic uint64_t submitted, completed, failed, unavailable;
    _Atomic uint64_t pipeline_cache_hits,pipeline_cache_misses,pipeline_cache_writes;
    _Atomic uint64_t pipeline_compile_ns,pipeline_compile_max_ns;
    _Atomic uint64_t gpu_duration_ns,gpu_max_ns;
}
@property(nonatomic,readonly) id<MTL4Compiler> compiler;
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (HvMetal4Job *)begin;
- (id)pipeline:(id)descriptor tag:(uint32_t)tag bundle:(HvPipelineBundle *)bundle;
- (void)setArchiveAdmission:(BOOL)enabled;
- (void)retainResource:(id)resource job:(HvMetal4Job *)job;
- (HvMetal4Arguments *)table:(HvMetal4Job *)job;
- (void)discard:(HvMetal4Job *)job;
- (BOOL)commit:(HvMetal4Job *)job classicQueue:(id<MTLCommandQueue>)classic
          lock:(os_unfair_lock *)lock drawable:(id<MTLDrawable>)drawable
    completion:(void(^)(BOOL))completion;
@end

@implementation HvMetal4Runtime
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self=[super init])) return nil;
    if (@available(macOS 26.0,iOS 26.0,*)) {
        if (![device supportsFamily:MTLGPUFamilyMetal4]) return nil;
        _device=device; _poolLock=OS_UNFAIR_LOCK_INIT; _pool=[NSMutableArray new];atomic_store(&_retainIdleResources,true);
        NSError *error=nil;
        _queue=[device newMTL4CommandQueueWithDescriptor:[MTL4CommandQueueDescriptor new] error:&error];
        _compileLock=[NSLock new];_cacheAdmission=YES;
        pipelineQueue=[HvMetal4CompileQueue new];
        _archiveQueue=dispatch_queue_create("hengevm.metal4.archive",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
        NSURL *support=[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask]firstObject];
        NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;
        NSString *identity=[NSString stringWithFormat:@"%@/%@/%ld.%ld/%@/schema1",device.architecture.name,NSBundle.mainBundle.bundleIdentifier?:@"Henge",(long)os.majorVersion,(long)os.minorVersion,NSProcessInfo.processInfo.operatingSystemVersionString];
        NSString *folder=hv_bundle_sha([identity dataUsingEncoding:NSUTF8StringEncoding]);
        _cacheDirectory=[[support URLByAppendingPathComponent:@"Henge/Metal4" isDirectory:YES]URLByAppendingPathComponent:folder isDirectory:YES];
        [self pruneArchiveFiles];[self resetCompiler];[self loadArchives];
        _bridge=[device newSharedEvent];
        if (!_queue || !_compiler || !_bridge) return nil;
        return self;
    }
    return nil;
}
- (void)pruneArchiveFiles {
    /* One bounded disk budget across old OS/GPU namespaces, not one allowance
       per update. This runs only on creation/save, never on a frame timer. */
    NSFileManager *fm=NSFileManager.defaultManager;NSMutableArray<NSURL *> *files=[NSMutableArray new];
    NSURL *root=[_cacheDirectory URLByDeletingLastPathComponent];
    for(NSURL *directory in [fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]){
        NSNumber *isDirectory=nil;[directory getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];if(!isDirectory.boolValue)continue;
        for(NSURL *file in [fm contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLFileSizeKey,NSURLContentModificationDateKey] options:0 error:nil]){
            if([file.pathExtension isEqual:@"mtl4a"])[files addObject:file];
            else if([file.pathExtension isEqual:@"new"]){NSDate *date=nil;[file getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];if(date&&date.timeIntervalSinceNow < -86400)[fm removeItemAtURL:file error:nil];}
        }
    }
    [files sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){
        NSDate *ad=nil,*bd=nil;[a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil];[b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];return [bd compare:ad];
    }];
    uint64_t bytes=0;NSUInteger count=0;
    for(NSURL *file in files){NSNumber *size=nil;[file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        uint64_t n=size.unsignedLongLongValue;
        if(!n||n>(64u<<20)||count>=32||bytes>(128u<<20)-n)[fm removeItemAtURL:file error:nil];
        else{bytes+=n;count++;}
    }
}
- (void)resetCompiler {
    _capture=nil;_pendingPipelines=0;_urgentSaveScheduled=NO;
    MTL4CompilerDescriptor *compiler=[MTL4CompilerDescriptor new];
    if(_cacheAdmission){
        MTL4PipelineDataSetSerializerDescriptor *d=[MTL4PipelineDataSetSerializerDescriptor new];
        d.configuration=MTL4PipelineDataSetSerializerConfigurationCaptureBinaries;
        _capture=[_device newPipelineDataSetSerializerWithDescriptor:d];
        compiler.pipelineDataSetSerializer=_capture;
    }
    _compiler=[_device newCompilerWithDescriptor:compiler error:nil];
}
- (void)loadArchives {
    if(!_cacheAdmission){_archives=@[];return;}
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray<NSURL *> *files=[fm contentsOfDirectoryAtURL:_cacheDirectory includingPropertiesForKeys:@[NSURLFileSizeKey,NSURLContentModificationDateKey] options:0 error:nil];
    files=[files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){
        NSDate *ad=nil,*bd=nil;[a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil];[b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];return [bd compare:ad];
    }];
    NSMutableArray *loaded=[NSMutableArray new];NSUInteger total=0;
    for(NSURL *url in files){
        if(![url.pathExtension isEqual:@"mtl4a"])continue;
        NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if(!size||!size.unsignedLongLongValue||size.unsignedLongLongValue>(64u<<20)||loaded.count==16||total>(64u<<20)-size.unsignedLongLongValue){[fm removeItemAtURL:url error:nil];continue;}
        id<MTL4Archive> archive=[_device newArchiveWithURL:url error:nil];
        if(archive){[loaded addObject:archive];total+=size.unsignedIntegerValue;}
        else [fm removeItemAtURL:url error:nil]; /* disposable, exact OS/GPU-scoped cache */
    }
    _archives=[loaded copy];
}
- (void)flushPipelines {
    [_compileLock lock];_saveScheduled=NO;
    if(!_cacheAdmission||!_pendingPipelines||!_capture){[_compileLock unlock];return;}
    id<MTL4PipelineDataSetSerializer> capture=_capture;
    __attribute__((objc_precise_lifetime)) id<MTL4Compiler> oldCompiler=_compiler;
    (void)oldCompiler;
    /* Hand future compiles to a fresh epoch before disk I/O. The old compiler
       remains alive with its serializer, and can never capture concurrently
       with serialization. The utility serial queue bounds concurrent saves. */
    [self resetCompiler];[_compileLock unlock];
    NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtURL:_cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *final=[_cacheDirectory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mtl4a"]];
    NSURL *temporary=[final URLByAppendingPathExtension:@"new"];NSError *error=nil;
    BOOL saved=[capture serializeAsArchiveAndFlushToURL:temporary error:&error];
    if(saved){NSNumber *size=nil;[temporary getResourceValue:&size forKey:NSURLFileSizeKey error:nil];saved=size.unsignedLongLongValue>255&&size.unsignedLongLongValue<=(64u<<20);}
    if(saved)saved=[fm moveItemAtURL:temporary toURL:final error:&error];
    if(saved){atomic_fetch_add(&pipeline_cache_writes,1);[self pruneArchiveFiles];[_compileLock lock];[self loadArchives];[_compileLock unlock];}
    else{[fm removeItemAtURL:temporary error:nil];fprintf(stderr,"hengevm: metal4-pipeline-cache: save unavailable; existing archives retained (%s)\n",error.localizedDescription.UTF8String?:"size limit");}
}
- (void)applyArchiveAdmissionLocked {
    BOOL requested=atomic_load(&_retainIdleResources);
    if(_cacheAdmission!=requested){_cacheAdmission=requested;[self resetCompiler];[self loadArchives];}
}
- (id)pipeline:(id)descriptor tag:(uint32_t)tag bundle:(HvPipelineBundle *)bundle {
    if(!descriptor)return nil;
    /* Bundled display archives are immutable and presenter-owned. A hit
       needs no mutable compiler/capture state, so it must not wait behind an
       optional guest shader compilation just to show the first frame. */
    for(id<MTL4Archive> archive in (bundle?bundle->archives:@[])) {
        id ready=nil;
        if(tag==0xe)ready=[archive newRenderPipelineStateWithDescriptor:descriptor error:nil];
        else ready=[archive newComputePipelineStateWithDescriptor:descriptor error:nil];
        if(ready){atomic_fetch_add(&pipeline_cache_hits,1);bundle->hits++;return ready;}
    }
    [_compileLock lock];
    @try {
    [self applyArchiveAdmissionLocked];
    id state=nil;
    for(NSArray *list in @[_archives?:@[]]){
        for(id<MTL4Archive> a in list){
            if(tag==0xe)state=[a newRenderPipelineStateWithDescriptor:descriptor error:nil];
            else state=[a newComputePipelineStateWithDescriptor:descriptor error:nil];
            if(state)break;
        }
        if(state)break;
    }
    if(state){atomic_fetch_add(&pipeline_cache_hits,1);if(bundle)bundle->hits++;}
    else{
        atomic_fetch_add(&pipeline_cache_misses,1);if(bundle)bundle->misses++;
        NSError *error=nil;
        struct timespec compileStart={0},compileEnd={0};
        clock_gettime(CLOCK_MONOTONIC,&compileStart);
        if(tag==0xe)state=[_compiler newRenderPipelineStateWithDescriptor:descriptor compilerTaskOptions:nil error:&error];
        else state=[_compiler newComputePipelineStateWithDescriptor:descriptor compilerTaskOptions:nil error:&error];
        clock_gettime(CLOCK_MONOTONIC,&compileEnd);
        uint64_t elapsed=(uint64_t)((int64_t)(compileEnd.tv_sec-compileStart.tv_sec)*1000000000ll+compileEnd.tv_nsec-compileStart.tv_nsec);
        atomic_fetch_add(&pipeline_compile_ns,elapsed);
        uint64_t peak=atomic_load(&pipeline_compile_max_ns);
        while(elapsed>peak&&!atomic_compare_exchange_weak(&pipeline_compile_max_ns,&peak,elapsed)){}
        if(state&&atomic_load(&_retainIdleResources)&&_cacheAdmission&&_capture){
            _pendingPipelines++;
            if(_pendingPipelines>=128&&!_urgentSaveScheduled){
                _urgentSaveScheduled=YES;__weak HvMetal4Runtime *owner=self;
                dispatch_async(_archiveQueue,^{[owner flushPipelines];});
            }
            if(!_saveScheduled){
                _saveScheduled=YES;__weak HvMetal4Runtime *owner=self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),_archiveQueue,^{[owner flushPipelines];});
            }
        }
    }
    return state;
    }@finally{
        @try{[self applyArchiveAdmissionLocked];}@finally{[_compileLock unlock];}
    }
}
- (void)setArchiveAdmission:(BOOL)enabled {
    [pipelineQueue setEnabled:enabled];
    BOOL changed=atomic_exchange(&_retainIdleResources,enabled)!=enabled;
    if(changed&&!enabled){os_unfair_lock_lock(&_poolLock);_created-=_pool.count;[_pool removeAllObjects];os_unfair_lock_unlock(&_poolLock);}
    /* This is called by the render worker's budget refresh. Never wait for
       a cold compiler here; its finally block consumes the latest request. */
    if([_compileLock tryLock]){
        @try{[self applyArchiveAdmissionLocked];}@finally{[_compileLock unlock];}
    }else if(changed){
        /* A serializer may own the lock instead of a compiler. Consume the
           latest request after its disk work; never leave an idle cache at
           the previous admission level if there are no more guest frames. */
        dispatch_async(_archiveQueue,^{
            [self->_compileLock lock];
            @try{[self applyArchiveAdmissionLocked];}@finally{[self->_compileLock unlock];}
        });
    }
}
- (id<MTL4Compiler>)compiler { return _compiler; }
- (HvMetal4Job *)begin {
    if(atomic_load(&failed)){atomic_fetch_add(&unavailable,1);return nil;}
    HvMetal4Job *job=nil;
    os_unfair_lock_lock(&_poolLock);
    if (_pool.count) { job=_pool.lastObject; [_pool removeLastObject]; }
    else if (_created<16) { _created++; job=[HvMetal4Job new]; }
    os_unfair_lock_unlock(&_poolLock);
    if (!job) { atomic_fetch_add(&unavailable,1); return nil; }
    if (!job->allocator) {
        job->allocator=[_device newCommandAllocator]; job->buffer=[_device newCommandBuffer];
        MTLResidencySetDescriptor *d=[MTLResidencySetDescriptor new];d.initialCapacity=64;
        job->residency=[_device newResidencySetWithDescriptor:d error:nil];
        job->keep=[NSMutableSet new];job->allocations=[NSMutableSet new];job->tables=[NSMutableArray new];job->fenceWaits=[NSMutableOrderedSet new];job->fenceUpdates=[NSMutableOrderedSet new];
    } else [job->allocator reset];
    if (!job->buffer || !job->allocator || !job->residency) {
        os_unfair_lock_lock(&_poolLock); _created--; os_unfair_lock_unlock(&_poolLock);
        atomic_fetch_add(&unavailable,1); return nil;
    }
    job->nextTable=0;
    [job->buffer beginCommandBufferWithAllocator:job->allocator];
    return job;
}
- (void)retainResource:(id)resource job:(HvMetal4Job *)job {
    if (!resource) return;
    [job->keep addObject:resource];
    id allocation=resource;
    if ([resource conformsToProtocol:@protocol(MTLTexture)]) {
        id<MTLTexture> t=resource; while(t.parentTexture)t=t.parentTexture;
        allocation=t.buffer ?: (id)t;
    }
    if ([allocation conformsToProtocol:@protocol(MTLResource)]) {
        id<MTLHeap> heap=((id<MTLResource>)allocation).heap;
        if(heap)allocation=heap;
    } else if (![allocation conformsToProtocol:@protocol(MTLHeap)]) return;
    if (![job->allocations containsObject:allocation]) {
        [job->allocations addObject:allocation];[job->residency addAllocation:allocation];
    }
}
- (HvMetal4Arguments *)table:(HvMetal4Job *)job {
    NSUInteger index=job->nextTable++;
    HvMetal4Arguments *table=index<job->tables.count?job->tables[index]:nil;
    if(table){[table clearForReuse];return table;}
    MTL4ArgumentTableDescriptor *d=[MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount=31;d.maxTextureBindCount=128;d.maxSamplerStateBindCount=16;
    d.supportAttributeStrides=YES;
    table=[[HvMetal4Arguments alloc]initWithTable:[_device newArgumentTableWithDescriptor:d error:nil]];
    if(table)[job->tables addObject:table];
    return table;
}
- (void)returnJob:(HvMetal4Job *)job {
    [job->residency removeAllAllocations];[job->residency commit];
    [job->allocations removeAllObjects];[job->keep removeAllObjects];[job->fenceWaits removeAllObjects];[job->fenceUpdates removeAllObjects];
    /* A single unusual guest submission cannot leave an unbounded high-water
       collection of argument tables in every idle job. */
    if(job->tables.count>64)[job->tables removeObjectsInRange:NSMakeRange(64,job->tables.count-64)];
    os_unfair_lock_lock(&_poolLock);
    if(atomic_load(&_retainIdleResources))[_pool addObject:job];else _created--;
    os_unfair_lock_unlock(&_poolLock);
}
- (void)discard:(HvMetal4Job *)job {
    [job->buffer endCommandBuffer];[self returnJob:job];
}
- (BOOL)commit:(HvMetal4Job *)job classicQueue:(id<MTLCommandQueue>)classic
          lock:(os_unfair_lock *)lock drawable:(id<MTLDrawable>)drawable
    completion:(void(^)(BOOL))completion {
    [job->residency commit];[job->buffer useResidencySet:job->residency];[job->buffer endCommandBuffer];
    MTL4CommitOptions *options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        BOOL ok=feedback.error==nil;
        if(!ok){
            if(self->_bridge.signaledValue<job->bridgeOutput)self->_bridge.signaledValue=job->bridgeOutput;
            atomic_fetch_add(&self->failed,1);fprintf(stderr,"hengevm: metal4: GPU submission failed: %s\n",feedback.error.description.UTF8String);}
        NSTimeInterval duration=feedback.GPUEndTime-feedback.GPUStartTime;
        if(isfinite(duration)&&duration>0&&duration<3600){
            uint64_t ns=(uint64_t)(duration*1e9);atomic_fetch_add(&self->gpu_duration_ns,ns);
            uint64_t old=atomic_load(&self->gpu_max_ns);
            while(ns>old&&!atomic_compare_exchange_weak(&self->gpu_max_ns,&old,ns)){}
        }
        atomic_fetch_add(&self->completed,1);
        [self returnJob:job];
        if(completion)completion(ok);
    }];
    os_unfair_lock_lock(lock);
    uint64_t input=++_bridgeValue,output=++_bridgeValue;job->bridgeOutput=output;
    NSArray *fenceWaits=job->fenceWaits.array,*fenceUpdates=job->fenceUpdates.array;
    id<MTLCommandBuffer> before=[classic commandBuffer],after=[classic commandBuffer];
    if(!before||!after){
        os_unfair_lock_unlock(lock);atomic_fetch_add(&unavailable,1);[self returnJob:job];return NO;
    }
    if(fenceWaits.count){
        id<MTLComputeCommandEncoder> fences=[before computeCommandEncoder];
        if(!fences){os_unfair_lock_unlock(lock);atomic_fetch_add(&unavailable,1);[self returnJob:job];return NO;}
        for(id<MTLFence> fence in fenceWaits)[fences waitForFence:fence];[fences endEncoding];
    }
    [before encodeSignalEvent:_bridge value:input];
    [after encodeWaitForEvent:_bridge value:output];
    if(fenceUpdates.count){
        id<MTLComputeCommandEncoder> fences=[after computeCommandEncoder];
        if(!fences){os_unfair_lock_unlock(lock);atomic_fetch_add(&unavailable,1);[self returnJob:job];return NO;}
        for(id<MTLFence> fence in fenceUpdates)[fences updateFence:fence];[fences endEncoding];
    }
    /* Finish every allocation/encoding step before submitting anything. A
       failed bridge can then reject the whole uncommitted operation safely. */
    [before commit];
    [_queue waitForEvent:_bridge value:input];
    if(drawable)[_queue waitForDrawable:drawable];
    id<MTL4CommandBuffer> buffers[]={job->buffer};
    [_queue commit:buffers count:1 options:options];
    [_queue signalEvent:_bridge value:output];
    if(drawable){[_queue signalDrawable:drawable];[drawable present];}
    [after commit];
    atomic_fetch_add(&submitted,1);
    os_unfair_lock_unlock(lock);return YES;
}
@end

static inline MTL4LibraryFunctionDescriptor *hv_metal4_function(id<MTLLibrary> library,NSString *name) API_AVAILABLE(macos(26.0),ios(26.0));
static inline MTL4LibraryFunctionDescriptor *hv_metal4_function(id<MTLLibrary> library,NSString *name) {
    if(!library || ![library.functionNames containsObject:name])return nil;
    MTL4LibraryFunctionDescriptor *d=[MTL4LibraryFunctionDescriptor new];d.library=library;d.name=name;return d;
}
