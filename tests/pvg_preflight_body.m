#import <Foundation/Foundation.h>
#include "pvg_shader_broker.h"
#include "pvg_replay_queue.h"
#import "HGOnDeviceShaderProvider.h"
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
static NSString *fixtureRoot,*fixtureSource;
#define NSSearchPathForDirectoriesInDomains(a,b,c) @[fixtureRoot]
static uint8_t memory[16384];static uint64_t generation=1;static unsigned observedPayload;
static uint64_t hv_pvg_lite_task_objects(void*p,uint32_t t){(void)p;(void)t;return 0x100;}
static uint64_t hv_pvg_lite_task_generation(void*p,uint32_t t){(void)p;(void)t;return generation;}
static int hv_pvg_lite_task_read(void*p,uint32_t t,uint64_t at,void*out,uint32_t n){(void)p;(void)t;if(at+n>sizeof memory)return -1;memcpy(out,memory+at,n);return 0;}
enum{OBJ_FUNCTION=6,OBJ_SERIALIZED=7};
@interface HvObject:NSObject{@public id object;uint32_t entry[3];}@end
@implementation HvObject @end
@interface HvReplay:NSObject{@public void*lite;HvReplayCommand*activeCommand;BOOL preflighting,preflightWaiting;NSMutableDictionary*tasks;HGOnDeviceShaderProvider *shaderProvider;NSString *shaderProviderError;}
- (int)shaderRead:(uint64_t)off task:(uint32_t)task to:(void*)to length:(uint32_t)n;
- (HvObject*)object:(uint32_t)ref task:(uint32_t)task;
- (HGOnDeviceShaderResult*)requestLocalShader:(NSData*)bytes sourceSHA:(NSString*)sha;
@end
@implementation HvReplay
- (instancetype)init{if((self=[super init]))tasks=[NSMutableDictionary new];return self;}
- (void)complain:(NSString*)s{(void)s;}
- (HGOnDeviceShaderResult*)requestLocalShader:(NSData*)bytes sourceSHA:(NSString*)sha{(void)bytes;(void)sha;return nil;}
/* The private Metal deserializer is replaced only in this CPU fixture.
 * Actual preflight parser and byte capture bodies follow unchanged. */
- (HvObject*)object:(uint32_t)ref task:(uint32_t)task {
 NSMutableDictionary*dict=tasks[@(task)];if(!dict)tasks[@(task)]=dict=[NSMutableDictionary new];
 HvObject*o=dict[@(ref)];if(o&&o->object)return o;
 o=[HvObject new];dict[@(ref)]=o;[self shaderRead:0x100+ref*12 task:task to:o->entry length:12];
 uint32_t value;[self shaderRead:o->entry[1] task:task to:&value length:4];
 if((o->entry[0]&255)==7){o->object=[self object:value task:task]->object;return o;}
 observedPayload=value;
 if(hv_shader_cached_bytes(fixtureRoot,fixtureSource)){o->object=@YES;return o;}
 NSDictionary*request=hv_shader_enqueue_request(fixtureRoot,fixtureSource,nil);
 if(request)activeCommand->requests[fixtureSource]=request;preflightWaiting=YES;return o;
}
// ACTUAL_METHODS
@end
static unsigned checks;
#define C(...) do{checks++;if(!(__VA_ARGS__)){fprintf(stderr,"FAIL %d\n",__LINE__);return 1;}}while(0)
static void J(NSString*p,id v){[[NSJSONSerialization dataWithJSONObject:v options:0 error:nil]writeToFile:p atomically:YES];}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 64;NSDictionary*f=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])]options:0 error:nil];fixtureSource=f[@"source"];
 fixtureRoot=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[NSFileManager.defaultManager createDirectoryAtPath:fixtureRoot withIntermediateDirectories:YES attributes:nil error:nil];
 J([fixtureRoot stringByAppendingPathComponent:@"shader-compiler-config.json"],f[@"config"]);NSMutableDictionary*lease=[f[@"config"]mutableCopy];lease[@"owner"]=NSUUID.UUID.UUIDString;J([fixtureRoot stringByAppendingPathComponent:@"shader-compiler.json"],lease);
 uint32_t pe[3]={7,0x800,0},fe[3]={6,0x900,0};memcpy(memory+0x100+12,pe,12);memcpy(memory+0x100+24,fe,12);*(uint32_t*)(memory+0x800)=2;*(uint32_t*)(memory+0x900)=1234;
 uint32_t records[5]={12,0,116,12,1};memcpy(memory+0x1000,records,sizeof records);
 uint32_t cmd[12]={0x43,48,77,1,1,1,1,2,0x1000,0,20,0};HvReplayCommand*item=[HvReplayCommand new];item->command=[NSData dataWithBytes:cmd length:sizeof cmd];item->task=1;item->generation=1;
 HvReplay*r=[HvReplay new];HvOrderedReplay*q=[HvOrderedReplay new];C([q reserve:item->command.length]);[q enqueue:item];__block unsigned writes=0,stamps=0;
 HvReplayReadiness(^pre)(HvReplayCommand*)=^HvReplayReadiness(HvReplayCommand*p){return[r preflightCommand:p];};
 void(^execute)(HvReplayCommand*)=^(HvReplayCommand*p){(void)p;writes++;stamps++;};
 void(^barrier)(HvReplayCommand*)=^(HvReplayCommand*p){(void)p;};
 [q pump:pre execute:execute barrier:barrier];C(writes==0&&stamps==0);C(q->entries.count==1);C(item->requests.count==1);C(observedPayload==1234);C(item->buffers.count==1);
 NSString*uuid=item->requests[fixtureSource][@"request"];
 for(int i=0;i<5;i++)[q pump:pre execute:execute barrier:barrier];C(writes==0&&stamps==0);C([uuid isEqual:item->requests[fixtureSource][@"request"]]);
 /* A parked batch must retain the exact bytes it inspected. */
 *(uint32_t*)(memory+0x900)=9999;((uint32_t*)(memory+0x1000))[4]=99;
 NSString*folder=[[fixtureRoot stringByAppendingPathComponent:@"shader-cache"]stringByAppendingPathComponent:f[@"recipe"]];[NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
 NSData*bytes=[[NSData alloc]initWithBase64EncodedString:f[@"bytes"]options:0];[bytes writeToFile:[folder stringByAppendingPathComponent:[fixtureSource stringByAppendingString:@".metallib"]]atomically:YES];J([folder stringByAppendingPathComponent:[fixtureSource stringByAppendingString:@".json"]],f[@"receipt"]);
 [q pump:pre execute:execute barrier:barrier];C(writes==1&&stamps==1);C(!q->entries.count);C(!q->faulted);C(observedPayload==1234);C(((const uint32_t*)[item->buffers[@0] bytes])[4]==1);
 [q pump:pre execute:execute barrier:barrier];C(writes==1&&stamps==1);C(!atomic_load(&q->reserved));

 /* Exercise compute pipeline and query-only discovery without a shader in the
    declared resource list: dependencies must come from actual record parsing. */
 for(unsigned variant=0;variant<2;variant++){
  uint32_t ordinary[3]={1,0,0};memcpy(memory+0x100+36,ordinary,12);cmd[6]=3;
  records[1]=variant?4:1;records[2]=variant?450:208;records[3]=12;records[4]=1;memcpy(memory+0x1000,records,sizeof records);
  [NSFileManager.defaultManager removeItemAtPath:[folder stringByAppendingPathComponent:[fixtureSource stringByAppendingString:@".json"]]error:nil];
  J([fixtureRoot stringByAppendingPathComponent:@"shader-compiler.json"],lease);
  HvReplayCommand*next=[HvReplayCommand new];next->command=[NSData dataWithBytes:cmd length:sizeof cmd];next->task=1;next->generation=1;
  HvReplay*rr=[HvReplay new];C([rr preflightCommand:next]==HvReplayPark);C(next->requests.count==1);
  J([folder stringByAppendingPathComponent:[fixtureSource stringByAppendingString:@".json"]],f[@"receipt"]);
  C([rr preflightCommand:next]==HvReplayReady);C(!next->error);
 }
 records[3]=1000;memcpy(memory+0x1000,records,sizeof records);
 HvReplayCommand*bad=[HvReplayCommand new];bad->command=[NSData dataWithBytes:cmd length:sizeof cmd];bad->task=1;bad->generation=1;
 HvReplay*rr=[HvReplay new];C([rr preflightCommand:bad]==HvReplayFault);C(bad->error!=nil);C(writes==1&&stamps==1);
 [NSFileManager.defaultManager removeItemAtPath:fixtureRoot error:nil];printf("%u actual preflight parser/snapshot/park/resume checks passed; fake descriptor resolver, no GPU\n",checks);return 0;
}}
