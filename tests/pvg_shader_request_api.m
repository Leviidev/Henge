#import <Foundation/Foundation.h>
#include "pvg_shader_broker.h"
static unsigned checks;
#define CHECK(x) do { checks++; if(!(x)){fprintf(stderr,"failed line %d\n",__LINE__);return 1;} }while(0)
static void J(NSString*p,id x){[[NSJSONSerialization dataWithJSONObject:x options:0 error:nil]writeToFile:p atomically:YES];}
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 64;
 NSDictionary *fixture=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])]options:0 error:nil];
 NSString *root=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
 NSString *source=fixture[@"source"],*recipe=fixture[@"recipe"],*owner=NSUUID.UUID.UUIDString;
 NSDictionary *config=@{@"protocol":@3,@"target":@"air64-apple-ios17.0.0",@"recipe":recipe};
 J([root stringByAppendingPathComponent:@"shader-compiler-config.json"],config);
 CHECK(hv_shader_enqueue_request(root,source,nil)==nil);
 NSMutableDictionary *lease=[config mutableCopy];lease[@"owner"]=owner;J([root stringByAppendingPathComponent:@"shader-compiler.json"],lease);
 NSDictionary *one=hv_shader_enqueue_request(root,source,@"first");CHECK(one!=nil);
 NSDictionary *two=hv_shader_enqueue_request(root,source,@"second");CHECK([one[@"request"]isEqual:two[@"request"]]);
 CHECK([hv_shader_poll_request(root,one)[@"state"]isEqual:@"pending"]);
 NSString *folder=[[root stringByAppendingPathComponent:@"shader-cache"]stringByAppendingPathComponent:recipe];
 [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
 NSString *path=[folder stringByAppendingPathComponent:[source stringByAppendingString:@".json"]];
 NSMutableDictionary *failure=[one mutableCopy];failure[@"status"]=@"failed";failure[@"retryable"]=@YES;J(path,failure);
 CHECK([hv_shader_poll_request(root,one)[@"state"]isEqual:@"retrying"]);
 failure[@"retryable"]=@NO;J(path,failure);CHECK([hv_shader_poll_request(root,one)[@"state"]isEqual:@"failed"]);
 failure[@"request"]=NSUUID.UUID.UUIDString;J(path,failure);CHECK([hv_shader_poll_request(root,one)[@"state"]isEqual:@"pending"]);
 lease[@"owner"]=NSUUID.UUID.UUIDString;J([root stringByAppendingPathComponent:@"shader-compiler.json"],lease);
 CHECK([hv_shader_poll_request(root,one)[@"state"]isEqual:@"offline"]);
 NSDictionary *fresh=hv_shader_enqueue_request(root,source,nil);CHECK(![fresh[@"request"]isEqual:one[@"request"]]);
 NSData *bytes=[[NSData alloc]initWithBase64EncodedString:fixture[@"bytes"]options:0];
 [bytes writeToFile:[folder stringByAppendingPathComponent:[source stringByAppendingString:@".metallib"]]atomically:YES];J(path,fixture[@"receipt"]);
 CHECK([hv_shader_poll_request(root,fresh)[@"state"]isEqual:@"ready"]);
 [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:@"shader-compiler.json"]error:nil];
 CHECK([hv_shader_poll_request(root,fresh)[@"state"]isEqual:@"ready"]);
 NSMutableData *bad=[bytes mutableCopy];((uint8_t*)bad.mutableBytes)[bad.length-1]^=1;
 [bad writeToFile:[folder stringByAppendingPathComponent:[source stringByAppendingString:@".metallib"]]atomically:YES];
 CHECK(![hv_shader_poll_request(root,fresh)[@"state"]isEqual:@"ready"]);
 NSMutableDictionary *changed=[config mutableCopy];changed[@"recipe"]=[@"b"stringByPaddingToLength:64 withString:@"b"startingAtIndex:0];J([root stringByAppendingPathComponent:@"shader-compiler-config.json"],changed);
 CHECK([hv_shader_poll_request(root,fresh)[@"state"]isEqual:@"stale"]);
 [NSFileManager.defaultManager removeItemAtPath:root error:nil];printf("%u checks passed; Foundation-only file protocol, no GPU or guest\n",checks);return 0;
}}
