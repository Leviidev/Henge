#import <Foundation/Foundation.h>
#include "pvg_shader_profile.h"
@interface TestFunction:NSObject
@property(copy)NSString*name;
@property MTLFunctionType functionType;
@end
@implementation TestFunction
@end
int main(int argc,char**argv){@autoreleasepool{if(argc!=2)return 64;NSArray*fixtures=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])]options:0 error:nil];NSMutableArray*results=[NSMutableArray new];BOOL all=YES;for(NSDictionary*c in fixtures){NSData*b=[[NSData alloc]initWithBase64EncodedString:c[@"output"]options:0];NSDictionary*p=nil;BOOL valid=hv_shader_profile_validate(c[@"receipt"],b,c[@"source"],c[@"recipe"],&p);TestFunction*f=[TestFunction new];f.name=c[@"function_name"];f.functionType=[c[@"function_type"]integerValue];BOOL attached=hv_shader_profile_attach((id<MTLFunction>)f,c[@"receipt"],b,c[@"source"],c[@"recipe"]);BOOL flag=hv_shader_function_gl_clip((id<MTLFunction>)f);BOOL ok=valid==[c[@"valid"]boolValue]&&attached==[c[@"attach"]boolValue]&&flag==[c[@"flag"]boolValue];all&=ok;[results addObject:@{@"id":c[@"id"],@"valid":@(valid),@"attach":@(attached),@"flag":@(flag),@"pass":@(ok)}];}NSData*j=[NSJSONSerialization dataWithJSONObject:@{@"all_pass":@(all),@"test_kind":@"profile_binding_and_selected_function_role_unit",@"cases":results}options:NSJSONWritingPrettyPrinted error:nil];fwrite(j.bytes,1,j.length,stdout);return all?0:1;}}
