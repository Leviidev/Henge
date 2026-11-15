/* Manifest admission uses production loader; archive creation is a recording
 * device so malformed-file coverage does not require a Metal4 GPU. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include "../devices/pipeline_bundle.h"
@interface BundleDevice : NSObject
@property(nonatomic) NSUInteger opened;
@end
@implementation BundleDevice
- (id)architecture {return self;}
- (NSString *)name {return @"applegpu_fixture";}
- (id)newArchiveWithURL:(NSURL *)url error:(NSError **)error {(void)url;(void)error;_opened++;return [NSObject new];}
@end
int main(void){@autoreleasepool{
    NSURL *folder=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableData *bytes=[NSMutableData dataWithLength:512];memset(bytes.mutableBytes,0x64,bytes.length);
    [bytes writeToURL:[folder URLByAppendingPathComponent:@"test.mtl4a"] atomically:YES];
    NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;
    NSDictionary *valid=@{@"file":@"test.mtl4a",@"gpu":@"applegpu_fixture",@"platform":@"macos",@"os_major":@(os.majorVersion),@"sha256":hv_bundle_sha(bytes)};
    for(unsigned variant=0;variant<8;variant++){
        NSMutableDictionary *entry=[valid mutableCopy];NSMutableDictionary *index=[@{@"schema":@1,@"archives":@[entry]} mutableCopy];
        if(variant==1)entry[@"gpu"]=@"applegpu_other";
        if(variant==2)entry[@"platform"]=@"ios";
        if(variant==3)entry[@"os_major"]=@0;
        if(variant==4)entry[@"sha256"]=[@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0];
        if(variant==5)entry[@"file"]=@"../test.mtl4a";
        if(variant==6)index[@"schema"]=@2;
        if(variant==7)index[@"archives"]=@[@"wrong-type"];
        [[NSJSONSerialization dataWithJSONObject:index options:0 error:nil]writeToURL:[folder URLByAppendingPathComponent:@"index.json"] atomically:YES];
        BundleDevice *device=[BundleDevice new];HvPipelineBundle *bundle=[[HvPipelineBundle alloc]initWithDevice:(id)device directory:folder];
        assert(device.opened==(variant==0?1:0));if(bundle)assert(bundle->archives.count==(variant==0?1:0));
    }
    [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
    puts("PASS pipeline bundle admission: exact GPU/OS/platform/hash, incompatible schema, wrong types and path traversal (recording archive loader)");return 0;
}}
