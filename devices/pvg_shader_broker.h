/* Shared first-use AIR conversion. The SSH companion owns a short-lived lease;
 * only a matching source/recipe/output receipt can supply bytes. Cached output
 * works offline. Called on the GPU replay worker, never the UIKit main thread.
 * No guarantee for AIR that the selected compiler cannot translate. */
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include "pvg_shader_profile.h"

#define HV_SHADER_LIMIT (32u * 1024u * 1024u)

static BOOL hv_shader_digest_valid(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static NSString *hv_shader_digest(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *text = [NSMutableString new];
    for (unsigned i = 0; i < sizeof hash; i++) [text appendFormat:@"%02x", hash[i]];
    return text;
}

static NSData *hv_shader_read(NSString *path, NSUInteger limit) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular] || [attrs[NSFileSize] unsignedLongLongValue] > limit) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data.length <= limit ? data : nil;
}

static NSDictionary *hv_shader_json(NSString *path) {
    NSData *data = hv_shader_read(path, 8192);
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL hv_shader_config_valid(NSDictionary *value) {
    return ([value[@"protocol"] isEqual:@2] || [value[@"protocol"] isEqual:@3]) && [value[@"target"] isEqual:@"air64-apple-ios17.0.0"] &&
           hv_shader_digest_valid(value[@"recipe"]);
}

static NSDictionary *hv_shader_lease(NSString *root, NSString *recipe) {
    NSString *path = [root stringByAppendingPathComponent:@"shader-compiler.json"];
    NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    NSTimeInterval age = modified ? -modified.timeIntervalSinceNow : 1e9;
    if (age < -1 || age > 2) return nil;
    NSDictionary *lease = hv_shader_json(path);
    if (!hv_shader_config_valid(lease) || ![lease[@"recipe"] isEqual:recipe] ||
        ![lease[@"owner"] isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:lease[@"owner"]]) return nil;
    return lease;
}

static NSData *hv_shader_cache(NSString *root, NSString *source, NSString *recipe) {
    NSString *base = [[[root stringByAppendingPathComponent:@"shader-cache"]
                      stringByAppendingPathComponent:recipe] stringByAppendingPathComponent:source];
    NSDictionary *receipt = hv_shader_json([base stringByAppendingString:@".json"]);
    if (!hv_shader_config_valid(receipt) || ![receipt[@"recipe"] isEqual:recipe] ||
        ![receipt[@"sha256"] isEqual:source] || ![receipt[@"status"] isEqual:@"ready"] ||
        !hv_shader_digest_valid(receipt[@"output_sha256"])) return nil;
    NSData *data = hv_shader_read([base stringByAppendingString:@".metallib"], HV_SHADER_LIMIT);
    if (data.length < 4 || memcmp(data.bytes, "MTLB", 4) ||
        ![receipt[@"length"] isEqual:@(data.length)] ||
        ![hv_shader_digest(data) isEqual:receipt[@"output_sha256"]]) return nil;
    NSDictionary *active=hv_shader_json([root stringByAppendingPathComponent:@"shader-compiler-config.json"]);
    if (![receipt[@"protocol"] isEqual:active[@"protocol"]]) return nil;
    if ([receipt[@"protocol"] isEqual:@3] && !hv_shader_profile_validate(receipt,data,source,recipe,NULL)) return nil;
    return data;
}

static NSDictionary *hv_shader_compiler_config(NSString *root) {
    NSDictionary *config = hv_shader_json([root stringByAppendingPathComponent:@"shader-compiler-config.json"]);
    return hv_shader_config_valid(config) ? config : nil;
}

static BOOL hv_shader_profile_required(NSString *root) {
    return [hv_shader_compiler_config(root)[@"protocol"] isEqual:@3];
}

/* This lookup never creates a request, checks a lease, or waits. It is safe to
 * prefer a verified existing conversion before trying a macOS library. */
static NSData *hv_shader_cached_bytes(NSString *root, NSString *source) {
    if (!hv_shader_digest_valid(source)) return nil;
    NSDictionary *config = hv_shader_compiler_config(root);
    return config ? hv_shader_cache(root, source, config[@"recipe"]) : nil;
}

static NSData *hv_shader_converted_bytes(NSString *root, NSString *source, NSString *function) {
    if (!hv_shader_digest_valid(source)) return nil;
    NSDictionary *config = hv_shader_compiler_config(root);
    if (!config) return nil;
    NSString *recipe = config[@"recipe"];
    NSData *cached = hv_shader_cache(root, source, recipe);
    if (cached) return cached;
    NSDictionary *lease = hv_shader_lease(root, recipe);
    if (!lease) return nil; // no wait and no unserviceable request when offline
    NSString *owner = lease[@"owner"];
    // A timed-out companion must not impose another deadline for every shader
    // in this frame. A new companion lease permits another attempt.
    static NSString *timedOutOwner;
    static NSObject *guard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ guard = [NSObject new]; });
    NSString *requests = [root stringByAppendingPathComponent:[config[@"protocol"]isEqual:@3]?@"shader-requests-v3":@"shader-requests-v2"];
    NSString *path = [requests stringByAppendingPathComponent:[source stringByAppendingString:@".json"]];
    NSString *requestID;
    @synchronized (guard) {
        if ([timedOutOwner isEqual:owner]) return nil;
        NSDictionary *existing = hv_shader_json(path);
        if (hv_shader_config_valid(existing) && [existing[@"recipe"] isEqual:recipe] &&
            [existing[@"owner"] isEqual:owner] && [existing[@"sha256"] isEqual:source] &&
            [existing[@"request"] isKindOfClass:NSString.class] &&
            [[NSUUID alloc] initWithUUIDString:existing[@"request"]]) {
            requestID = existing[@"request"];
        } else {
            requestID = NSUUID.UUID.UUIDString;
            NSDictionary *request = @{@"protocol":config[@"protocol"], @"target":@"air64-apple-ios17.0.0", @"recipe":recipe,
                @"sha256":source, @"owner":owner, @"request":requestID, @"function":function ?: @"(library load)"};
            [NSFileManager.defaultManager createDirectoryAtPath:requests withIntermediateDirectories:YES attributes:nil error:nil];
            NSData *encoded = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
            if (![encoded writeToFile:path options:NSDataWritingAtomic error:nil]) return nil;
        }
    }
    NSString *receiptPath = [[[[root stringByAppendingPathComponent:@"shader-cache"]
                              stringByAppendingPathComponent:recipe] stringByAppendingPathComponent:source]
                             stringByAppendingString:@".json"];
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime;
    fprintf(stderr, "hengevm: shader-broker: first use %s function=%s\n", source.UTF8String, function.UTF8String ?: "(library load)");
    while (NSProcessInfo.processInfo.systemUptime - started < 12) {
        cached = hv_shader_cache(root, source, recipe);
        if (cached) {
            fprintf(stderr, "hengevm: shader-broker: ready %s after %.3fs\n", source.UTF8String,
                    NSProcessInfo.processInfo.systemUptime - started);
            return cached;
        }
        NSDictionary *receipt = hv_shader_json(receiptPath);
        if ([receipt[@"recipe"] isEqual:recipe] && [receipt[@"sha256"] isEqual:source] &&
            [receipt[@"request"] isEqual:requestID] && [receipt[@"owner"] isEqual:owner] &&
            [receipt[@"status"] isEqual:@"failed"]) {
            fprintf(stderr, "hengevm: shader-broker: failed %s: %s\n", source.UTF8String,
                    [receipt[@"error"] description].UTF8String);
            return nil;
        }
        if (![hv_shader_lease(root, recipe)[@"owner"] isEqual:owner]) {
            fprintf(stderr, "hengevm: shader-broker: disconnected %s\n", source.UTF8String);
            return nil;
        }
        [NSThread sleepForTimeInterval:0.025];
    }
    @synchronized (guard) { timedOutOwner = owner; }
    fprintf(stderr, "hengevm: shader-broker: deadline reached; further waits disabled for lease %s\n", owner.UTF8String);
    return nil;
}

/* Selection policy shared by initial library loading and a failed pipeline's
 * function retry. The loader must return nil for unusable bytes/functions;
 * file presence alone must never suppress a verified broker result. Requests
 * remain opt-in, used only where the caller already attempted the original. */
static id hv_shader_load_converted(NSString *root, NSString *source, NSString *legacyPath,
        NSString *function, BOOL allowLegacy, BOOL allowRequest,
        id (^load)(NSData *), NSString *__autoreleasing *route) {
    if (route) *route = nil;
    if (!hv_shader_digest_valid(source) || !load) return nil;
    if (hv_shader_profile_required(root)) return nil; // protocol3 requires the annotated loader below
    NSData *cached = hv_shader_cached_bytes(root, source);
    id result = cached ? load(cached) : nil;
    if (result) { if (route) *route = @"recipe-cache"; return result; }
    NSData *legacy = allowLegacy && legacyPath ? hv_shader_read(legacyPath, HV_SHADER_LIMIT) : nil;
    if (legacy.length && ![legacy isEqualToData:cached]) result = load(legacy);
    if (result) { if (route) *route = @"legacy"; return result; }
    if (!allowRequest) return nil;
    NSData *converted = hv_shader_converted_bytes(root, source, function);
    /* Do not retry the same rejected output just because its receipt is valid. */
    if (converted.length && ![converted isEqualToData:cached] && ![converted isEqualToData:legacy])
        result = load(converted);
    if (result && route) *route = @"broker";
    return result;
}

/* Protocol3 never loads unprofiled bytes. Protocol2 preserves its existing policy. */
static id hv_shader_load_profiled(NSString *root, NSString *source, NSString *legacyPath,
        NSString *function, BOOL allowLegacy, BOOL allowRequest,
        id (^load)(NSData *, NSDictionary *, NSString *), NSString *__autoreleasing *route) {
    if (route) *route=nil;
    if (!hv_shader_digest_valid(source)||!load) return nil;
    NSDictionary *config=hv_shader_compiler_config(root);
    if (![config[@"protocol"]isEqual:@3])
        return hv_shader_load_converted(root,source,legacyPath,function,allowLegacy,allowRequest,
            ^id(NSData *bytes){ return load(bytes,nil,nil); },route);
    NSString *recipe=config[@"recipe"];
    NSString *base=[[[root stringByAppendingPathComponent:@"shader-cache"]stringByAppendingPathComponent:recipe]stringByAppendingPathComponent:source];
    NSData *cached=hv_shader_cache(root,source,recipe);
    NSDictionary *receipt=hv_shader_json([base stringByAppendingString:@".json"]);
    id result=cached&&hv_shader_profile_validate(receipt,cached,source,recipe,NULL)?load(cached,receipt,recipe):nil;
    if(result){if(route)*route=@"profiled-recipe-cache";return result;}
    NSData *legacy=allowLegacy&&legacyPath?hv_shader_read(legacyPath,HV_SHADER_LIMIT):nil;
    NSDictionary *legacyReceipt=legacyPath?hv_shader_json([legacyPath stringByAppendingString:@".profile.json"]):nil;
    if(legacy.length&&![legacy isEqualToData:cached]&&hv_shader_profile_validate(legacyReceipt,legacy,source,recipe,NULL))result=load(legacy,legacyReceipt,recipe);
    if(result){if(route)*route=@"profiled-legacy";return result;}
    if(!allowRequest)return nil;
    NSData *converted=hv_shader_converted_bytes(root,source,function);
    receipt=hv_shader_json([base stringByAppendingString:@".json"]);
    if(converted.length&&![converted isEqualToData:cached]&&hv_shader_profile_validate(receipt,converted,source,recipe,NULL))result=load(converted,receipt,recipe);
    if(result&&route)*route=@"profiled-broker";
    return result;
}
