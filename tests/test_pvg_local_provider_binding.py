"""Exact replay binding helpers with an authored memory-only provider fixture."""
from pathlib import Path
import base64,hashlib,json,subprocess,tempfile,sys
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'ios/scripts'));from shader_profile import envelope
s=(root/'devices/pvg_metal.m').read_text();methods=[]
for name in ['- (HGOnDeviceShaderResult *)retainLocalResult:', '- (HGOnDeviceShaderResult *)requestLocalShader:']:
 a=s.index(name);b=s.index('\n}\n',a)+3;methods.append(s[a:b])
body='''#import <Foundation/Foundation.h>
#include "pvg_shader_profile.h"
#include "pvg_replay_queue.h"
#import "HGOnDeviceShaderProvider.h"
@interface HGOnDeviceShaderResult()
@property(nonatomic,readwrite)HGOnDeviceShaderStatus status;
@property(nonatomic,copy,readwrite)NSString *sourceSHA,*recipe,*route;
@property(nonatomic,copy,readwrite)NSData *output;
@property(nonatomic,copy,readwrite)NSDictionary *receipt,*timings;
@property(nonatomic,strong,readwrite)NSError *error;
@end
@implementation HGOnDeviceShaderResult @end
@interface HGOnDeviceShaderProvider(){@public HGOnDeviceShaderResult *current;unsigned requests;dispatch_block_t savedWake;dispatch_queue_t savedQueue;}
@end
@implementation HGOnDeviceShaderProvider
- (instancetype)initWithDocuments:(NSString*)documents error:(NSError**)error{(void)documents;(void)error;return [super init];}
- (instancetype)initWithDocuments:(NSString*)documents cacheNamespace:(NSString*)name error:(NSError**)error{(void)name;return[self initWithDocuments:documents error:error];}
- (NSString*)recipe{return @"fixture";}
- (NSString*)cacheNamespace{return @"fixture";}
- (HGOnDeviceShaderResult*)snapshotForSourceSHA:(NSString*)sha{(void)sha;return current;}
- (HGOnDeviceShaderResult*)requestSource:(NSData*)bytes sourceSHA:(NSString*)sha completionQueue:(dispatch_queue_t)queue completion:(dispatch_block_t)wake{(void)bytes;(void)sha;requests++;savedWake=[wake copy];savedQueue=queue;current.route=@"queued";return current;}
- (void)invalidate{savedWake=nil;}
@end
@interface HvReplay:NSObject{@public HvReplayCommand *activeCommand;HGOnDeviceShaderProvider *shaderProvider;NSString *shaderProviderError;dispatch_queue_t worker;_Atomic int stopping,wakes;}
- (void)pumpCommands;
@end
@implementation HvReplay
- (void)pumpCommands{atomic_fetch_add(&wakes,1);}
METHODS
@end
#define C(...) do{checks++;if(!(__VA_ARGS__)){fprintf(stderr,"FAIL %d\\n",__LINE__);return 1;}}while(0)
int main(int argc,char**argv){@autoreleasepool{if(argc!=2)return 64;unsigned checks=0;NSDictionary*f=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])]options:0 error:nil];
 HGOnDeviceShaderResult*p=[HGOnDeviceShaderResult new];p.status=HGOnDeviceShaderPending;p.route=@"not-requested";p.sourceSHA=f[@"source"];p.recipe=f[@"recipe"];
 HGOnDeviceShaderProvider*provider=[[HGOnDeviceShaderProvider alloc]initWithDocuments:@"unused" error:nil];provider->current=p;
 HvReplay*r=[HvReplay new];r->activeCommand=[HvReplayCommand new];r->shaderProvider=provider;r->worker=dispatch_queue_create("binding-test",DISPATCH_QUEUE_SERIAL);
 NSMutableData*input=[[@"immutable authored input" dataUsingEncoding:NSUTF8StringEncoding]mutableCopy];NSData*before=[input copy];NSString*sha=f[@"source"];
 C([r requestLocalShader:input sourceSHA:sha].status==HGOnDeviceShaderPending);C(provider->requests==1);C(r->activeCommand->localSources.count==1);C(r->activeCommand->snapshotBytes==input.length);
 ((uint8_t*)input.mutableBytes)[0]^=1;C([r->activeCommand->localSources[sha]isEqual:before]);[r requestLocalShader:input sourceSHA:sha];C(provider->requests==1);
 HGOnDeviceShaderResult*ready=[HGOnDeviceShaderResult new];ready.status=HGOnDeviceShaderReady;ready.sourceSHA=sha;ready.recipe=f[@"recipe"];ready.route=@"ondevice-compiled";ready.receipt=f[@"receipt"];ready.output=[[NSData alloc]initWithBase64EncodedString:f[@"bytes"]options:0];provider->current=ready;
 C([r requestLocalShader:input sourceSHA:sha]==ready);C(r->activeCommand->localSources.count==0);C(r->activeCommand->localResults[sha]==ready);C(r->activeCommand->snapshotBytes==ready.output.length);
 provider->current=p;p.route=@"not-requested";C([r requestLocalShader:input sourceSHA:sha]==ready);C(provider->requests==1);
 dispatch_async(provider->savedQueue,provider->savedWake);dispatch_sync(r->worker,^{});C(atomic_load(&r->wakes)==1);atomic_store(&r->stopping,1);dispatch_async(provider->savedQueue,provider->savedWake);dispatch_sync(r->worker,^{});C(atomic_load(&r->wakes)==1);
 r->activeCommand=[HvReplayCommand new];r->activeCommand->snapshotBytes=128u*1024u*1024u-1;C([r requestLocalShader:input sourceSHA:sha]==nil);C(r->activeCommand->error!=nil);C(provider->requests==1);
 r->activeCommand=[HvReplayCommand new];provider->current=ready;ready.sourceSHA=@"wrong";C([r requestLocalShader:input sourceSHA:sha]==nil);C(r->activeCommand->localResults.count==0);C(r->activeCommand->error!=nil);ready.sourceSHA=sha;
 r->activeCommand=[HvReplayCommand new];provider->current=[HGOnDeviceShaderResult new];provider->current.status=HGOnDeviceShaderFailed;provider->current.error=[NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"unsupported authored control"}];C([r requestLocalShader:input sourceSHA:sha].status==HGOnDeviceShaderFailed);C([r->activeCommand->error isEqual:@"unsupported authored control"]);
 printf("%u actual local-provider binding/retention/budget/identity/wake checks passed; fake provider, no compiler/GPU\\n",checks);return 0;
}}
'''.replace('METHODS','\n'.join(methods))
b=b'MTLB-authored-binding';identity='a'*64;recipe='c'*64;receipt=dict(protocol=3,target='air64-apple-ios17.0.0',status='ready',sha256=identity,recipe=recipe,output_sha256=hashlib.sha256(b).hexdigest(),length=len(b),transformation_profile=envelope(dict(schema=1,gl_clip_zero_to_one=False,vertex_functions=[],viewport_contract=None),identity,recipe,b))
with tempfile.TemporaryDirectory()as t:
 p=Path(t);(p/'test.m').write_text(body);(p/'fixture.json').write_text(json.dumps(dict(source=identity,recipe=recipe,receipt=receipt,bytes=base64.b64encode(b).decode())))
 subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wno-incompatible-pointer-types','-Wno-deprecated-declarations','-I'+str(root/'devices'),str(p/'test.m'),'-framework','Foundation','-framework','Metal','-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'fixture.json')],check=True)
