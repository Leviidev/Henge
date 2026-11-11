#import "HGOnDeviceDynamicService.h"
#import "HGOnDeviceCompilerRecipe.h"
#import "dynamic/HGStatelessLink.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <string.h>

static const NSUInteger WireLimit = 24u << 20, DecodedLimit = 16u << 20;
static NSString *digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *result = [NSMutableString new];
    for (unsigned char byte : bytes) [result appendFormat:@"%02x", byte];
    return result;
}
static BOOL text(id value, NSUInteger limit) {
    return [value isKindOfClass:NSString.class] && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= limit &&
        [value rangeOfString:[NSString stringWithCharacters:(const unichar[]){0} length:1]].location == NSNotFound;
}
static BOOL sha(id value) {
    return text(value,64) && [value length] == 64 &&
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static BOOL keys(NSDictionary *value, NSArray *names) {
    return [value isKindOfClass:NSDictionary.class] && value.count == names.count &&
        [[NSSet setWithArray:value.allKeys] isEqual:[NSSet setWithArray:names]];
}
static int reply(int status, NSDictionary *object, void **out, size_t *length) {
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    if (!bytes || bytes.length > WireLimit) return 500;
    void *owned = malloc(bytes.length);
    if (!owned) return 500;
    memcpy(owned, bytes.bytes, bytes.length); *out = owned; *length = bytes.length;
    return status;
}
static NSDictionary *rejected(NSString *key, NSString *message) {
    return @{@"schema":@1,@"recipe":@HG_ONDEVICE_COMPILER_RECIPE,@"request_sha256":key,
             @"status":@"rejected",@"error":message?:@"Invalid stateless closure request"};
}

// Runs only on HGOnDeviceCompilerQueue, shared with ordinary AIR conversion.
static NSDictionary *compile(NSData *raw, NSString *key) {
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    if (!keys(request,@[@"schema",@"recipe",@"consumer",@"libraries",@"preloaded_sha256",@"compile_install_names",@"function_name",@"origin_semantics"]) ||
        ![request[@"schema"] isKindOfClass:NSNumber.class] || [request[@"schema"] intValue] != 1 ||
        ![request[@"recipe"] isEqual:@HG_ONDEVICE_COMPILER_RECIPE] ||
        ![request[@"origin_semantics"] isEqual:@"guest-resolved-file-urls"] ||
        !text(request[@"function_name"],1024) || ![request[@"function_name"] length])
        return rejected(key,@"Request schema, recipe or function identity mismatch");
    NSArray *dependencies=request[@"libraries"], *preloads=request[@"preloaded_sha256"], *required=request[@"compile_install_names"];
    if (![dependencies isKindOfClass:NSArray.class] || dependencies.count>16 ||
        ![preloads isKindOfClass:NSArray.class] || preloads.count>32 ||
        ![required isKindOfClass:NSArray.class] || required.count>16)
        return rejected(key,@"Dependency inventory exceeds the supported bound");
    NSMutableArray<NSData *> *sources=[NSMutableArray new];
    NSMutableArray<NSString *> *origins=[NSMutableArray new];
    NSMutableDictionary<NSString *,NSNumber *> *rows=[NSMutableDictionary new];
    NSUInteger total=0;
    for (id row in [@[request[@"consumer"]] arrayByAddingObjectsFromArray:dependencies]) {
        if (!keys(row,@[@"sha256",@"source_base64",@"origin_url"]) || !sha(row[@"sha256"]) ||
            !text(row[@"source_base64"],WireLimit) || rows[row[@"sha256"]])
            return rejected(key,@"Invalid or duplicate library identity");
        NSData *source=[[NSData alloc] initWithBase64EncodedString:row[@"source_base64"] options:0];
        if (source.length<88 || source.length>DecodedLimit-total ||
            ![[source base64EncodedStringWithOptions:0] isEqual:row[@"source_base64"]] ||
            ![digest(source) isEqual:row[@"sha256"]])
            return rejected(key,@"Library digest, encoding or decoded byte bound mismatch");
        NSString *origin=@"";
        if (row[@"origin_url"] != NSNull.null) {
            if (!text(row[@"origin_url"],12288)) return rejected(key,@"Invalid origin URL");
            NSString *declared=row[@"origin_url"];
            NSURL *url=[declared isAbsolutePath]?[NSURL fileURLWithPath:declared]:[NSURL URLWithString:declared];
            if (!url.isFileURL || (url.host.length && ![url.host isEqual:@"localhost"]) || url.query || url.fragment ||
                !text(url.path,4096) || !url.path.isAbsolutePath)
                return rejected(key,@"Origin must be a local absolute file URL");
            origin=url.path;
        }
        total+=source.length; rows[row[@"sha256"]]=@(sources.count);
        [sources addObject:source]; [origins addObject:origin];
    }
    uint32_t mask=0;
    for (id hash in preloads) {
        NSNumber *index=sha(hash)?rows[hash]:nil;
        if (!index || !index.unsignedIntValue) return rejected(key,@"Preloaded library identity missing");
        mask |= 1u << index.unsignedIntValue;
    }
    const char *requiredNames[16]={};
    for (NSUInteger i=0;i<required.count;++i) {
        if (!text(required[i],4096) || ![required[i] hasPrefix:@"/"])
            return rejected(key,@"Compile dependency needs an absolute install name");
        requiredNames[i]=[required[i] UTF8String];
    }
    const void *inputs[17]={}; size_t sizes[17]={}; const char *paths[17]={};
    for (NSUInteger i=0;i<sources.count;++i) { inputs[i]=sources[i].bytes; sizes[i]=sources[i].length; paths[i]=origins[i].UTF8String; }
    void *output=nullptr; size_t length=0; char *failure=nullptr;
    // Return a macOS-target library to the guest loader. Ordinary PVG shader
    // conversion subsequently retargets the linked AIR to iOS on this same queue.
    int rc=HGStatelessMetallibCloseRequired(inputs,sizes,paths,sources.count,mask,
        [request[@"function_name"] UTF8String],requiredNames,required.count,0,&output,&length,&failure);
    if (rc) { NSString *message=failure?@(failure):@"Stateless linker rejected request"; free(failure); free(output); return rejected(key,message); }
    NSData *binary=[NSData dataWithBytesNoCopy:output length:length freeWhenDone:YES];
    return @{@"schema":@1,@"recipe":@HG_ONDEVICE_COMPILER_RECIPE,@"request_sha256":key,
             @"status":@"ready",@"output_sha256":digest(binary),@"output_bytes":@(binary.length),
             @"output_base64":[binary base64EncodedStringWithOptions:0]};
}

int HGOnDeviceDynamicService(const char *method, const char *resource, const void *body,
    size_t length, void **response, size_t *responseLength) {
    if (!response || !responseLength) return 500;
    *response=nullptr; *responseLength=0;
    @autoreleasepool { @try {
        if (!method || !resource || strnlen(method,9)>8 || strnlen(resource,128)>127) return 400;
        if (!strcmp(method,"GET") && !strcmp(resource,"identity") && !length)
            return reply(200,@{@"schema":@1,@"recipe":@HG_ONDEVICE_COMPILER_RECIPE,
                @"policy":@"henge_stateless_compute_dynamic_1",@"protocol":@"embedded-close-v1"},response,responseLength);
        if (strcmp(method,"POST") || strncmp(resource,"close/",6)) return 404;
        NSString *key=@(resource+6);
        if (!sha(key) || !body || !length || length>WireLimit) return 400;
        // One synchronous closure request in flight process-wide, including
        // queued work and JSON decode. Ordinary provider admission remains bounded.
        static NSObject *guard; static dispatch_once_t once; static BOOL busy;
        dispatch_once(&once,^{guard=[NSObject new];});
        @synchronized(guard) { if(busy)return 429; busy=YES; }
        @try {
            NSData *raw=[NSData dataWithBytes:body length:length];
            if (![digest(raw) isEqual:key]) return 400;
            __block NSDictionary *result;
            dispatch_sync(HGOnDeviceCompilerQueue(),^{ @autoreleasepool {
                @try { result=compile(raw,key); }
                @catch(NSException *exception) { result=rejected(key,@"Malformed closure request"); }
            } });
            return reply(200,result,response,responseLength);
        } @finally { @synchronized(guard) {busy=NO;} }
    } @catch(NSException *exception) { return reply(400,@{@"error":@"Malformed closure request"},response,responseLength); } }
}
