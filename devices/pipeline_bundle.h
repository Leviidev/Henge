#pragma once
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
static inline NSString *hv_bundle_sha(NSData *data){
    if(!data)return nil;unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX context;CC_SHA256_Init(&context);const uint8_t *p=data.bytes;NSUInteger n=data.length;
    while(n){CC_LONG take=(CC_LONG)MIN(n,(NSUInteger)(1u<<20));CC_SHA256_Update(&context,p,take);p+=take;n-=take;}
    CC_SHA256_Final(digest,&context);char text[65];for(unsigned i=0;i<32;i++)snprintf(text+i*2,3,"%02x",digest[i]);return @(text);
}
API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvPipelineBundle : NSObject {
@public NSArray<id<MTL4Archive>> *archives;
    id<MTLLibrary> screenLibrary;
    uint64_t hits,misses;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device directory:(NSURL *)directory;
@end
@implementation HvPipelineBundle
- (instancetype)initWithDevice:(id<MTLDevice>)device directory:(NSURL *)directory {
    if(!(self=[super init]))return nil;
    NSData *index=[NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"index.json"]];
    if(!index||index.length>128*1024)return nil;
    NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:index options:0 error:nil];
    if(![manifest isKindOfClass:NSDictionary.class]||![manifest[@"schema"]isEqual:@1]||
       ![manifest[@"archives"]isKindOfClass:NSArray.class]||[manifest[@"archives"]count]>16)return nil;
    NSString *platform=TARGET_OS_IPHONE?@"ios":@"macos";
    NSOperatingSystemVersion os=NSProcessInfo.processInfo.operatingSystemVersion;
    NSMutableArray *loaded=[NSMutableArray new];NSUInteger total=0;
    NSDictionary *library=manifest[@"screen_library"];
    if([library isKindOfClass:NSDictionary.class]&&[library[@"file"]isEqual:@"screen.metallib"]){
        NSURL *url=[directory URLByAppendingPathComponent:@"screen.metallib"];
        NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if(size.unsignedLongLongValue && size.unsignedLongLongValue<=(4u<<20)){
            NSData *bytes=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
            if([hv_bundle_sha(bytes)isEqual:library[@"sha256"]])screenLibrary=[device newLibraryWithURL:url error:nil];
        }
    }
    for(id item in manifest[@"archives"]){
        if(![item isKindOfClass:NSDictionary.class])continue;
        NSString *file=item[@"file"],*gpu=item[@"gpu"],*sha=item[@"sha256"];
        if(![file isKindOfClass:NSString.class]||![file.lastPathComponent isEqual:file]||![file.pathExtension isEqual:@"mtl4a"]||
           ![gpu isKindOfClass:NSString.class]||![gpu isEqual:device.architecture.name]||
           ![item[@"platform"]isEqual:platform]||![item[@"os_major"]isEqual:@(os.majorVersion)]||
           ![sha isKindOfClass:NSString.class]||sha.length!=64)continue;
        NSURL *url=[directory URLByAppendingPathComponent:file];
        NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if(!size||size.unsignedLongLongValue>(128u<<20)||total>(128u<<20)-size.unsignedLongLongValue)continue;
        NSData *bytes=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        if(![[hv_bundle_sha(bytes)lowercaseString]isEqual:sha.lowercaseString])continue;
        NSError *error=nil;id<MTL4Archive> archive=[device newArchiveWithURL:url error:&error];
        if(archive){[loaded addObject:archive];total+=bytes.length;}
        else fprintf(stderr,"hengevm: pipeline-bundle: incompatible archive; normal compilation retained (%s)\n",error.localizedDescription.UTF8String);
        if(loaded.count==8)break;
    }
    archives=[loaded copy];
    fprintf(stderr,"hengevm: pipeline-bundle: gpu=%s archives=%lu bytes=%lu (exact architecture and archive integrity; normal miss fallback)\n",device.architecture.name.UTF8String,(unsigned long)archives.count,(unsigned long)total);
    return self;
}
@end
