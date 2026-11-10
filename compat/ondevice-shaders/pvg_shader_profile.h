#pragma once
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
/* Only validated protocol3 output can carry this flag. No filename inference.
 */
static char hv_shader_gl_clip_key;
static BOOL hv_sp_digest_valid(id x) {
  if (![x isKindOfClass:NSString.class] || [x length] != 64)
    return NO;
  NSCharacterSet *bad = [[NSCharacterSet
      characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
  return [x rangeOfCharacterFromSet:bad].location == NSNotFound;
}
static NSString *hv_sp_sha(NSData *d) {
  unsigned char h[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(d.bytes, (CC_LONG)d.length, h);
  NSMutableString *s = [NSMutableString new];
  for (unsigned i = 0; i < sizeof(h); i++)
    [s appendFormat:@"%02x", h[i]];
  return s;
}
static BOOL hv_sp_number(id x, NSUInteger expected) {
  if (![x isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)x) != CFNumberGetTypeID() ||
      CFNumberIsFloatType((__bridge CFNumberRef)x)) return NO;
  return [x compare:@(expected)] == NSOrderedSame;
}

static BOOL hv_shader_profile_validate(NSDictionary *receipt,
                                       NSData *loadedBytes, NSString *sourceSHA,
                                       NSString *recipeSHA,
                                       NSDictionary **decodedProfile) {
  if (decodedProfile)
    *decodedProfile = nil;
  if (![receipt isKindOfClass:NSDictionary.class] ||
      ![loadedBytes isKindOfClass:NSData.class] || loadedBytes.length < 4 ||
      loadedBytes.length > 32 * 1024 * 1024 ||
      memcmp(loadedBytes.bytes, "MTLB", 4) || !hv_sp_digest_valid(sourceSHA) ||
      !hv_sp_digest_valid(recipeSHA))
    return NO;
  if (!hv_sp_number(receipt[@"protocol"], 3) ||
      ![receipt[@"target"] isEqual:@"air64-apple-ios17.0.0"] ||
      ![receipt[@"status"] isEqual:@"ready"] ||
      ![receipt[@"sha256"] isEqual:sourceSHA] ||
      ![receipt[@"recipe"] isEqual:recipeSHA] ||
      !hv_sp_number(receipt[@"length"], loadedBytes.length) ||
      ![receipt[@"output_sha256"] isEqual:hv_sp_sha(loadedBytes)])
    return NO;
  NSDictionary *envelope = receipt[@"transformation_profile"];
  if (![envelope isKindOfClass:NSDictionary.class] || envelope.count != 4 ||
      !hv_sp_number(envelope[@"schema"], 1) ||
      ![envelope[@"data"] isKindOfClass:NSString.class] ||
      [envelope[@"data"] length] > 5500 ||
      !hv_sp_digest_valid(envelope[@"sha256"]) ||
      !hv_sp_digest_valid(envelope[@"binding_sha256"]))
    return NO;
  NSData *data = [[NSData alloc] initWithBase64EncodedString:envelope[@"data"]
                                                     options:0];
  if (!data || data.length > 4096 ||
      ![hv_sp_sha(data) isEqual:envelope[@"sha256"]])
    return NO;
  NSString *binding = [NSString
      stringWithFormat:@"henge-shader-profile-v1\n%@\n%@\n%@\n%lu\n%@\n",
                       sourceSHA, recipeSHA, receipt[@"output_sha256"],
                       (unsigned long)loadedBytes.length, envelope[@"sha256"]];
  if (![hv_sp_sha([binding dataUsingEncoding:NSASCIIStringEncoding])
          isEqual:envelope[@"binding_sha256"]])
    return NO;
  NSDictionary *profile = [NSJSONSerialization JSONObjectWithData:data
                                                          options:0
                                                            error:nil];
  if (![profile isKindOfClass:NSDictionary.class] || profile.count != 4 ||
      !hv_sp_number(profile[@"schema"], 1) ||
      ![profile[@"gl_clip_zero_to_one"] isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)profile[@"gl_clip_zero_to_one"]) !=
          CFBooleanGetTypeID())
    return NO;
  NSArray *names = profile[@"vertex_functions"];
  if (![names isKindOfClass:NSArray.class] || names.count > 16)
    return NO;
  NSMutableSet *seen = [NSMutableSet new];
  for (id name in names) {
    if (![name isKindOfClass:NSString.class] || ![name length] ||
        [name length] > 1024 || [seen containsObject:name])
      return NO;
    [seen addObject:name];
  }
  if ([profile[@"gl_clip_zero_to_one"] boolValue]) {
    if (!names.count ||
        ![profile[@"viewport_contract"] isEqual:@"gl_half_range_v1"])
      return NO;
  } else if (names.count || profile[@"viewport_contract"] != NSNull.null)
    return NO;
  if (decodedProfile)
    *decodedProfile = profile;
  return YES;
}
static BOOL hv_shader_profile_attach(id<MTLFunction> function,
                                     NSDictionary *receipt, NSData *loadedBytes,
                                     NSString *sourceSHA, NSString *recipeSHA) {
  if (!function)
    return NO;
  objc_setAssociatedObject(function, &hv_shader_gl_clip_key, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  NSDictionary *profile = nil;
  if (!hv_shader_profile_validate(receipt, loadedBytes, sourceSHA, recipeSHA,
                                  &profile))
    return NO;
  if ([profile[@"gl_clip_zero_to_one"] boolValue] &&
      ((function.functionType == MTLFunctionTypeVertex) !=
       [profile[@"vertex_functions"] containsObject:function.name])) return NO;
  BOOL applies = [profile[@"gl_clip_zero_to_one"] boolValue] &&
                 function.functionType == MTLFunctionTypeVertex &&
                 [profile[@"vertex_functions"] containsObject:function.name];
  objc_setAssociatedObject(function, &hv_shader_gl_clip_key, @(applies),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return YES;
}
static BOOL hv_shader_function_gl_clip(id<MTLFunction> function) {
  return function &&
         [objc_getAssociatedObject(function, &hv_shader_gl_clip_key) boolValue];
}
