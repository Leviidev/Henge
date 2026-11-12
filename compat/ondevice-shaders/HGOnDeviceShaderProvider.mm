#import "HGOnDeviceShaderProvider.h"
#import "HGOnDeviceAIR.h"
#import "HGOnDeviceCompilerRecipe.h"
#import "pvg_shader_profile.h"
#include <stdlib.h>
#include <float.h>
#include <string.h>
static const NSUInteger InputLimit=8*1024*1024, OutputLimit=16*1024*1024;
#ifndef HG_PROVIDER_PENDING_LIMIT
#define HG_PROVIDER_PENDING_LIMIT 8
#endif
static const NSUInteger PendingLimit=HG_PROVIDER_PENDING_LIMIT, PendingBytesLimit=32*1024*1024;
#ifdef HG_PROVIDER_TESTING
extern void HGProviderTestBeforeCompile(void);
#endif
static const NSUInteger ReadyLimit=128, ReadyBytesLimit=32*1024*1024;
static NSError* HGError(NSInteger code,NSString*message){return [NSError errorWithDomain:@"HengeOnDeviceShader" code:code userInfo:@{NSLocalizedDescriptionKey:message?:@"local compiler error"}];}
@interface HGOnDeviceShaderResult ()
@property(nonatomic,readwrite) HGOnDeviceShaderStatus status;
@property(nonatomic,copy,readwrite) NSString *sourceSHA,*recipe,*route;
@property(nonatomic,copy,readwrite) NSData *output;
@property(nonatomic,copy,readwrite) NSDictionary *receipt;
@property(nonatomic,copy,readwrite) NSDictionary *timings;
@property(nonatomic,strong,readwrite) NSError *error;
@end
@implementation HGOnDeviceShaderResult @end
@interface HGShaderWake:NSObject
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,copy) dispatch_block_t block;
@end
@implementation HGShaderWake @end
@interface HGShaderJob:NSObject
@property(nonatomic,copy) NSData*source;
@property(nonatomic,strong) HGOnDeviceShaderResult*result;
@property(nonatomic,strong) NSMutableDictionary<NSValue*,HGShaderWake*>*wakes;
@property(nonatomic) NSTimeInterval touched;
@property(nonatomic) NSUInteger reservedBytes;
@property(nonatomic,copy) NSString*requestID;
@property(nonatomic) NSTimeInterval enqueued;
@end
@implementation HGShaderJob @end
@interface HGOnDeviceShaderProvider ()
@property(nonatomic,copy,readwrite) NSString *recipe;
@property(nonatomic,copy,readwrite) NSString *cacheNamespace;
@property(nonatomic,copy) NSString *cacheRoot;
@property(nonatomic,strong) NSObject *guard;
@property(nonatomic,strong) dispatch_queue_t compilerQueue;
@property(nonatomic,strong) dispatch_queue_t callbackQueue;
@property(nonatomic,strong) NSMutableDictionary<NSString*,HGShaderJob*>*jobs;
@property(nonatomic,strong) NSMutableDictionary<NSValue*,HGShaderWake*>*capacityWakes;
@property(nonatomic) NSUInteger pendingCount,pendingBytes,readyBytes;
@property(nonatomic) BOOL invalidated;
@end
@implementation HGOnDeviceShaderProvider
- (instancetype)initWithDocuments:(NSString*)documents error:(NSError**)error{
 const char*value=getenv("HENGE_LOCAL_SHADER_CACHE_NAMESPACE");return [self initWithDocuments:documents cacheNamespace:value?@(value):@"production" error:error];
}
- (instancetype)initWithDocuments:(NSString*)documents cacheNamespace:(NSString*)cacheNamespace error:(NSError**)error{
 NSCharacterSet*bad=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"]invertedSet];
 if(!cacheNamespace.length||cacheNamespace.length>64||[cacheNamespace rangeOfCharacterFromSet:bad].location!=NSNotFound){if(error)*error=HGError(13,@"invalid local compiler cache namespace");return nil;}
 if(!(self=[super init]))return nil;
 NSData*manifest=[NSData dataWithBytes:HGOnDeviceCompilerRecipeJSON length:sizeof(HGOnDeviceCompilerRecipeJSON)-1];
 if(!documents.length||![hv_sp_sha(manifest)isEqual:@HG_ONDEVICE_COMPILER_RECIPE]){if(error)*error=HGError(1,@"local compiler recipe manifest mismatch");return nil;}
 _recipe=@HG_ONDEVICE_COMPILER_RECIPE;_cacheNamespace=[cacheNamespace copy];_cacheRoot=[[[[documents stringByAppendingPathComponent:@"shader-local-cache"]stringByAppendingPathComponent:_cacheNamespace]stringByAppendingPathComponent:_recipe]copy];
 _guard=[NSObject new];_jobs=[NSMutableDictionary new];_capacityWakes=[NSMutableDictionary new];
 static dispatch_queue_t sharedCompilerQueue;static dispatch_once_t once;dispatch_once(&once,^{sharedCompilerQueue=dispatch_queue_create("henge.local-air.compiler",DISPATCH_QUEUE_SERIAL);});_compilerQueue=sharedCompilerQueue;
 // Initialization itself performs no disk I/O. The serial job validates/creates storage.
 return self;
}
- (HGOnDeviceShaderResult*)result:(HGOnDeviceShaderStatus)status source:(NSString*)source route:(NSString*)route error:(NSError*)error{
 HGOnDeviceShaderResult*r=[HGOnDeviceShaderResult new];r.status=status;r.sourceSHA=source?:@"";r.recipe=self.recipe;r.route=route;r.error=error;r.timings=@{};return r;
}
- (HGOnDeviceShaderResult*)snapshotForSourceSHA:(NSString*)source{
 @synchronized(self.guard){if(self.invalidated)return [self result:HGOnDeviceShaderFailed source:source route:@"stopped" error:HGError(2,@"local compiler provider stopped")];HGShaderJob*j=self.jobs[source];if(j){j.touched=NSProcessInfo.processInfo.systemUptime;return j.result;}return [self result:HGOnDeviceShaderPending source:source route:@"not-requested" error:nil];}
}
- (void)addWake:(dispatch_block_t)block queue:(dispatch_queue_t)queue to:(NSMutableDictionary*)wakes{
 // Wake registrations coalesce per caller queue; they are not per-call completion promises.
 if(!block||!queue)return;NSValue*key=[NSValue valueWithPointer:(__bridge const void*)queue];
 if(wakes.count>=16&&!wakes[key])return;
 HGShaderWake*w=[HGShaderWake new];w.queue=queue;w.block=block;wakes[key]=w;
}
- (void)deliver:(NSArray<HGShaderWake*>*)wakes{
 __weak HGOnDeviceShaderProvider*weak=self;
 for(HGShaderWake*w in wakes)dispatch_async(w.queue,^{HGOnDeviceShaderProvider*owner=weak;if(!owner)return;@synchronized(owner.guard){if(owner.invalidated)return;}w.block();});
}
- (HGOnDeviceShaderResult*)requestSource:(NSData*)source sourceSHA:(NSString*)digest completionQueue:(dispatch_queue_t)queue completion:(dispatch_block_t)wake{
 digest=[digest copy];
 if(!queue||!wake||!hv_sp_digest_valid(digest)||![source isKindOfClass:NSData.class]||source.length<88||source.length>InputLimit)
  return [self result:HGOnDeviceShaderFailed source:digest route:@"input-limit" error:HGError(3,@"source identity/size outside supported local compiler limit")];
 HGShaderJob*job=nil;
 @synchronized(self.guard){
  if(self.invalidated)return [self result:HGOnDeviceShaderFailed source:digest route:@"stopped" error:HGError(2,@"local compiler provider stopped")];
  if(self.callbackQueue&&self.callbackQueue!=queue)return [self result:HGOnDeviceShaderFailed source:digest route:@"caller-contract" error:HGError(11,@"provider requires one replay completion queue")];
  if(!self.callbackQueue)self.callbackQueue=queue;
  job=self.jobs[digest];if(job){job.touched=NSProcessInfo.processInfo.systemUptime;if(job.result.status==HGOnDeviceShaderPending)[self addWake:wake queue:queue to:job.wakes];return job.result;}
  if(self.pendingCount>=PendingLimit||source.length>PendingBytesLimit-self.pendingBytes){[self addWake:wake queue:queue to:self.capacityWakes];return [self result:HGOnDeviceShaderPending source:digest route:@"backpressure" error:nil];}
  job=[HGShaderJob new];job.wakes=[NSMutableDictionary new];job.result=[self result:HGOnDeviceShaderPending source:digest route:@"queued" error:nil];job.requestID=NSUUID.UUID.UUIDString;job.enqueued=NSProcessInfo.processInfo.systemUptime;job.reservedBytes=source.length;job.touched=NSProcessInfo.processInfo.systemUptime;[self addWake:wake queue:queue to:job.wakes];self.jobs[digest]=job;self.pendingCount++;self.pendingBytes+=source.length;
 }
 // Deep copy: neither mutable caller NSData nor guest mappings survive into the compiler.
 HGOnDeviceShaderResult*pending=job.result;
 @try {NSData*snapshot=[NSData dataWithBytes:source.bytes length:source.length];@synchronized(self.guard){if(!self.invalidated)job.source=snapshot;}}
 @catch(NSException*x){dispatch_async(self.compilerQueue,^{[self finish:job result:[self result:HGOnDeviceShaderFailed source:digest route:@"snapshot-error" error:HGError(12,x.reason)]];});return pending;}
 dispatch_async(self.compilerQueue,^{@autoreleasepool{[self compileJob:job];}});return pending;
}
- (NSData*)read:(NSString*)path limit:(NSUInteger)limit{
 NSDictionary*a=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];if(![a[NSFileType]isEqual:NSFileTypeRegular]||[a[NSFileSize]unsignedLongLongValue]>limit)return nil;NSData*d=[NSData dataWithContentsOfFile:path];return d.length<=limit?d:nil;
}
- (NSDictionary*)json:(NSString*)path{
 NSData*d=[self read:path limit:16384];id value=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;return [value isKindOfClass:NSDictionary.class]?value:nil;
}
- (HGOnDeviceShaderResult*)cached:(NSString*)source{
 NSString*base=[self.cacheRoot stringByAppendingPathComponent:source];NSDictionary*receipt=[self json:[base stringByAppendingString:@".json"]];NSData*bytes=[self read:[base stringByAppendingString:@".metallib"]limit:OutputLimit];
 if([receipt[@"provider"]isEqual:@"ondevice-llvm14"]&&[receipt[@"cache_namespace"]isEqual:self.cacheNamespace]&&bytes&&hv_shader_profile_validate(receipt,bytes,source,self.recipe,NULL)){
  HGOnDeviceShaderResult*r=[self result:HGOnDeviceShaderReady source:source route:@"ondevice-cache" error:nil];r.output=bytes;r.receipt=receipt;return r;
 }
 if([receipt[@"provider"]isEqual:@"ondevice-llvm14"]&&[receipt[@"cache_namespace"]isEqual:self.cacheNamespace]&&[receipt[@"recipe"]isEqual:self.recipe]&&[receipt[@"sha256"]isEqual:source]&&[receipt[@"status"]isEqual:@"failed"]&&[receipt[@"error"]isKindOfClass:NSString.class])return [self result:HGOnDeviceShaderFailed source:source route:@"ondevice-terminal-error" error:HGError(4,receipt[@"error"])];
 return nil;
}
- (NSDictionary*)receiptForSource:(NSString*)source output:(NSData*)bytes profileData:(NSData*)profile{
 NSString*profileSHA=hv_sp_sha(profile),*outputSHA=hv_sp_sha(bytes);
 NSString*binding=[NSString stringWithFormat:@"henge-shader-profile-v1\n%@\n%@\n%@\n%lu\n%@\n",source,self.recipe,outputSHA,(unsigned long)bytes.length,profileSHA];
 return @{@"protocol":@3,@"target":@"air64-apple-ios17.0.0",@"status":@"ready",@"provider":@"ondevice-llvm14",@"sha256":source,@"recipe":self.recipe,@"output_sha256":outputSHA,@"length":@(bytes.length),@"transformation_profile":@{@"schema":@1,@"data":[profile base64EncodedStringWithOptions:0],@"sha256":profileSHA,@"binding_sha256":hv_sp_sha([binding dataUsingEncoding:NSUTF8StringEncoding])}};
}
- (void)finish:(HGShaderJob*)job result:(HGOnDeviceShaderResult*)result{
 NSArray*wakes;
 @synchronized(self.guard){self.pendingCount--;self.pendingBytes-=job.reservedBytes;job.source=nil;if(self.invalidated){[self.jobs removeObjectForKey:job.result.sourceSHA];return;}job.result=result;job.touched=NSProcessInfo.processInfo.systemUptime;self.readyBytes+=result.output.length;NSMutableArray*all=[job.wakes.allValues mutableCopy];[all addObjectsFromArray:self.capacityWakes.allValues];wakes=all;[job.wakes removeAllObjects];[self.capacityWakes removeAllObjects];
  while(self.jobs.count-self.pendingCount>ReadyLimit||self.readyBytes>ReadyBytesLimit){NSString*oldest=nil;NSTimeInterval time=DBL_MAX;for(NSString*key in self.jobs){HGShaderJob*j=self.jobs[key];if(j==job||j.result.status==HGOnDeviceShaderPending)continue;if(j.touched<time){time=j.touched;oldest=key;}}if(!oldest)break;self.readyBytes-=self.jobs[oldest].result.output.length;[self.jobs removeObjectForKey:oldest];}
 }
 [self deliver:wakes];
}
- (void)compileJob:(HGShaderJob*)job{
 NSString*source=job.result.sourceSHA;NSTimeInterval started=NSProcessInfo.processInfo.systemUptime,lookup=0,compile=0,write=0;
 NSData*input;@synchronized(self.guard){if(self.invalidated){[self finish:job result:job.result];return;}input=job.source;}
#ifdef HG_PROVIDER_TESTING
 HGProviderTestBeforeCompile();
#endif
 HGOnDeviceShaderResult*result=nil;NSError*error=nil;
 @try{
  if(![hv_sp_sha(input)isEqual:source])error=HGError(5,@"immutable source SHA mismatch");
  if(!error){NSTimeInterval before=NSProcessInfo.processInfo.systemUptime;result=[self cached:source];lookup=NSProcessInfo.processInfo.systemUptime-before;}
  if(!error&&!result){
   NSTimeInterval beforeCompile=NSProcessInfo.processInfo.systemUptime;
   void*out=NULL;size_t length=0;char*profile=NULL,*failure=NULL;int rc=HGOnDeviceAIRConvert(input.bytes,input.length,1,1,&out,&length,&profile,&failure);
   compile=NSProcessInfo.processInfo.systemUptime-beforeCompile;
   if(rc)error=HGError(6,failure?@(failure):@"local AIR converter rejected source");
   if(!rc&&(length<4||length>OutputLimit||!out||!profile))error=HGError(7,@"local compiler output outside supported bounds");
   NSData*bytes=!error?[NSData dataWithBytes:out length:length]:nil;NSData*profileData=!error?[NSData dataWithBytes:profile length:strnlen(profile,4097)]:nil;
   free(out);free(profile);free(failure);
   NSMutableDictionary*receipt=!error?[[self receiptForSource:source output:bytes profileData:profileData]mutableCopy]:nil;
   if(receipt){receipt[@"cache_namespace"]=self.cacheNamespace;receipt[@"request"]=job.requestID;receipt[@"producer_compile_seconds"]=@(compile);receipt[@"producer_queue_seconds"]=@(started-job.enqueued);receipt[@"producer_process_id"]=@(getpid());receipt[@"created_at"]=@([NSDate date].timeIntervalSince1970);}
   if(!error&&!hv_shader_profile_validate(receipt,bytes,source,self.recipe,NULL))error=HGError(8,@"local output/profile binding rejected");
   if(!error){
    @synchronized(self.guard){if(self.invalidated){[self finish:job result:job.result];return;}}
    NSTimeInterval beforeWrite=NSProcessInfo.processInfo.systemUptime;
    if(![NSFileManager.defaultManager createDirectoryAtPath:self.cacheRoot withIntermediateDirectories:YES attributes:nil error:&error]){}
    NSString*base=[self.cacheRoot stringByAppendingPathComponent:source];NSData*encoded=[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:&error];
    if(!error&&![bytes writeToFile:[base stringByAppendingString:@".metallib"]options:NSDataWritingAtomic error:&error]){}
    if(!error&&![encoded writeToFile:[base stringByAppendingString:@".json"]options:NSDataWritingAtomic error:&error]){}
    write=NSProcessInfo.processInfo.systemUptime-beforeWrite;
    if(!error){result=[self result:HGOnDeviceShaderReady source:source route:@"ondevice-compiled" error:nil];result.output=bytes;result.receipt=receipt;}
   }
  }
 }@catch(NSException*x){error=HGError(9,[NSString stringWithFormat:@"local compiler exception: %@",x.reason?:x.name]);}
 if(error){NSString*message=error.localizedDescription;if(message.length>2048)message=[message substringToIndex:2048];result=[self result:HGOnDeviceShaderFailed source:source route:@"ondevice-terminal-error" error:HGError(error.code,message)];
  BOOL active;@synchronized(self.guard){active=!self.invalidated;}if(active){[NSFileManager.defaultManager createDirectoryAtPath:self.cacheRoot withIntermediateDirectories:YES attributes:nil error:nil];NSDictionary*r=@{@"provider":@"ondevice-llvm14",@"cache_namespace":self.cacheNamespace,@"request":job.requestID,@"recipe":self.recipe,@"sha256":source,@"status":@"failed",@"error":message};NSData*d=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingSortedKeys error:nil];[d writeToFile:[[self.cacheRoot stringByAppendingPathComponent:source]stringByAppendingString:@".json"]options:NSDataWritingAtomic error:nil];}
 }
 result.timings=@{@"queue_seconds":@(started-job.enqueued),@"cache_lookup_seconds":@(lookup),@"compile_seconds":@(compile),@"cache_write_seconds":@(write),@"total_seconds":@(NSProcessInfo.processInfo.systemUptime-job.enqueued)};
 NSString*event=[result.route isEqual:@"ondevice-cache"]?@"cache-hit":(result.status==HGOnDeviceShaderReady?@"compiled":(compile>0?@"compile-failed":@"failed-or-terminal-cache"));
 fprintf(stderr,"hengevm: local-shader: event=%s request=%s producer_request=%s source=%s recipe=%s namespace=%s route=%s status=%ld queue=%.6f lookup=%.6f compile=%.6f write=%.6f bytes=%lu\n",event.UTF8String,job.requestID.UTF8String,[result.receipt[@"request"]UTF8String]?:"none",source.UTF8String,self.recipe.UTF8String,self.cacheNamespace.UTF8String,result.route.UTF8String,(long)result.status,started-job.enqueued,lookup,compile,write,(unsigned long)result.output.length);
 [self finish:job result:result?:[self result:HGOnDeviceShaderFailed source:source route:@"internal-error" error:HGError(10,@"local compiler produced no terminal result")]];
}
- (void)invalidate{@synchronized(self.guard){self.invalidated=YES;[self.capacityWakes removeAllObjects];for(NSString*key in self.jobs.allKeys){HGShaderJob*j=self.jobs[key];[j.wakes removeAllObjects];j.source=nil;if(j.result.status!=HGOnDeviceShaderPending)[self.jobs removeObjectForKey:key];}self.readyBytes=0;}}
#ifdef HG_PROVIDER_TESTING
- (void)hg_testDrain { dispatch_sync(self.compilerQueue,^{}); }
#endif
@end
