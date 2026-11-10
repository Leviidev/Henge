/* Experimental, process-local stateless compute adapter. Explicit opt-in only.
   File request/receipt exchange is a stateless adapter transport, not
   production support. */
#import <CommonCrypto/CommonDigest.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
@interface NSObject (HGSnapshot)
- (BOOL)serializeToURL:(NSURL *)url error:(NSError **)error;
@end
typedef id (*HGSourceFn)(id, SEL, id, id, NSError **)
    __attribute__((ns_returns_retained));
typedef id (*HGURLFn)(id, SEL, id, NSError **)
    __attribute__((ns_returns_retained));
typedef id (*HGFunctionFn)(id, SEL, id) __attribute__((ns_returns_retained));
typedef id (*HGPipelineFn)(id, SEL, id, NSUInteger, id *, NSError **)
    __attribute__((ns_returns_retained));
static NSString *HGRoot;
static char HGLibKey, HGFunctionKey;
static IMP HGSourceIMP, HGURLIMP, HGDataIMP, HGDynamicIMP, HGPipelineIMP,
    HGFunctionIMP;
static Class HGFunctionClass;
static IMP HGRenderBasicIMP, HGRenderOptionsIMP, HGRenderAsyncIMP,
    HGRenderAsyncOptionsIMP;
static _Thread_local BOOL HGInternal;
#ifndef HG_RECIPE_ID
#define HG_RECIPE_ID "missing_recipe"
#endif
static const char *HGRecipeID = HG_RECIPE_ID;
static NSString *HGSHA(NSData *d) {
  unsigned char h[32];
  CC_SHA256(d.bytes, (CC_LONG)d.length, h);
  NSMutableString *s = [NSMutableString new];
  for (int i = 0; i < 32; i++)
    [s appendFormat:@"%02x", h[i]];
  return s;
}
static id HGFail(NSError **e, NSInteger code, NSString *s) {
  if (e)
    *e = [NSError errorWithDomain:@"HengeDynamicLibraries"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : s}];
  return nil;
}
#include "transport.m"
static uint64_t HGU64(const uint8_t *b) {
  uint64_t x;
  memcpy(&x, b, 8);
  return x;
}
static uint16_t HGU16(const uint8_t *b) {
  uint16_t x;
  memcpy(&x, b, 2);
  return x;
}
static NSDictionary *HGHeader(NSData *d) {
  const uint8_t *b = d.bytes;
  NSUInteger n = d.length;
  if (n < 88 || memcmp(b, "MTLB", 4) || HGU64(b + 16) != n)
    return nil;
  uint64_t start = HGU64(b + 24), size = HGU64(b + 32), end = HGU64(b + 40);
  if (start > n || size > n - start || size + 4 > n - start || end > n)
    return nil;
  uint64_t at = start + size + 4;
  NSMutableArray *deps = [NSMutableArray new];
  NSString *name = nil;
  while (at + 4 <= end) {
    if (!memcmp(b + at, "ENDT", 4)) {
      at += 4;
      break;
    }
    if (at + 6 > end)
      return nil;
    uint64_t z = HGU16(b + at + 4);
    if (z > end - at - 6)
      return nil;
    if (!memcmp(b + at, "HDYN", 4)) {
      if (z != 16)
        return nil;
      uint64_t a = HGU64(b + at + 6), len = HGU64(b + at + 14);
      if (a > n || len > n - a)
        return nil;
      uint64_t stop = a + len;
      while (a + 4 <= stop) {
        if (!memcmp(b + a, "ENDT", 4)) {
          a += 4;
          break;
        }
        if (a + 6 > stop)
          return nil;
        uint64_t k = HGU16(b + a + 4);
        if (!k || k > stop - a - 6 || b[a + 6 + k - 1])
          return nil;
        NSString *v = [[NSString alloc] initWithBytes:b + a + 6
                                               length:k - 1
                                             encoding:NSUTF8StringEncoding];
        if (!v)
          return nil;
        if (!memcmp(b + a, "NAME", 4)) {
          if (name)
            return nil;
          name = v;
        } else if (!memcmp(b + a, "DYNL", 4))
          [deps addObject:v];
        else
          return nil;
        a += 6 + k;
      }
      if (a != stop)
        return nil;
    }
    at += 6 + z;
  }
  if (at != end)
    return nil;
  return @{
    @"type" : @(b[10]),
    @"install_name" : name ?: @"",
    @"dependencies" : deps
  };
}
@interface HGDynamic : NSObject <MTLDynamicLibrary>
@property(strong) id<MTLDevice> device;
@property(copy) NSString *label;
@property(strong) NSString *installName;
@property(strong) NSDictionary *record;
@end
@implementation HGDynamic
- (BOOL)serializeToURL:(NSURL *)url error:(NSError **)error {
  if (!url.isFileURL) {
    HGFail(
        error, 20,
        @"Only file URL serialization is supported by this stateless adapter");
    return NO;
  }
  return [self.record[@"data"] writeToURL:url
                                  options:NSDataWritingAtomic
                                    error:error];
}
@end
static NSDictionary *HGWire(NSDictionary *r) {
  return @{
    @"sha256" : r[@"sha256"],
    @"source_base64" : [r[@"data"] base64EncodedStringWithOptions:0],
    @"origin_url" : r[@"origin_url"] ?: NSNull.null
  };
}
static id __attribute__((ns_returns_retained)) HGFunction(id lib, SEL sel,
                                                          NSString *name) {
  id f = ((HGFunctionFn)HGFunctionIMP)(lib, sel, name);
  NSDictionary *r = objc_getAssociatedObject(lib, &HGLibKey);
  if (f && r)
    objc_setAssociatedObject(f, &HGFunctionKey,
                             @{@"library" : r, @"name" : name},
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return f;
}
static BOOL HGRecord(id lib, NSData *data, NSString *origin,
                     NSArray *compileDeps) {
  if (!lib)
    return NO;
  if (!data) {
    NSURL *u = [NSURL
        fileURLWithPath:[HGRoot
                            stringByAppendingPathComponent:
                                [@"snapshot-"
                                    stringByAppendingString:NSUUID.UUID
                                                                .UUIDString]]];
    NSError *e = nil;
    if (![lib respondsToSelector:@selector(serializeToURL:error:)] ||
        ![lib serializeToURL:u error:&e])
      return NO;
    data = [NSData dataWithContentsOfURL:u];
    [NSFileManager.defaultManager removeItemAtURL:u error:nil];
  }
  NSDictionary *h = HGHeader(data);
  if (!h || data.length > 16 * 1024 * 1024)
    return NO;
  NSDictionary *r = @{
    @"data" : data,
    @"sha256" : HGSHA(data),
    @"origin_url" : origin ?: NSNull.null,
    @"header" : h,
    @"compile_dependencies" : compileDeps ?: @[]
  };
  objc_setAssociatedObject(lib, &HGLibKey, r,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  @synchronized(HGDynamic.class) {
    Class c = [lib class];
    if (!HGFunctionClass) {
      HGFunctionClass = c;
      Method m = class_getInstanceMethod(c, @selector(newFunctionWithName:));
      HGFunctionIMP = method_getImplementation(m);
      class_replaceMethod(c, @selector(newFunctionWithName:), (IMP)HGFunction,
                          method_getTypeEncoding(m));
    } else if (c != HGFunctionClass)
      return NO;
  }
  return YES;
}
static id __attribute__((ns_returns_retained))
HGSource(id dev, SEL sel, NSString *s, MTLCompileOptions *options,
         NSError **error) {
  NSArray *deps = options.libraries ?: @[];
  for (id d in deps)
    if (![d isKindOfClass:HGDynamic.class])
      return HGFail(
          error, 21,
          @"Mixed native and compatibility dynamic libraries are unsupported");
  MTLCompileOptions *copy = [options copy] ?: [MTLCompileOptions new];
  if (deps.count) {
    copy.libraries = @[];
    copy.allowReferencingUndefinedSymbols = YES;
  }
  id l = ((HGSourceFn)HGSourceIMP)(dev, sel, s, copy, error);
  if (l && !HGRecord(l, nil, nil, deps) &&
      (deps.count || copy.libraryType == MTLLibraryTypeDynamic ||
       copy.allowReferencingUndefinedSymbols))
    return HGFail(error, 22, @"Could not preserve runtime source AIR snapshot");
  return l;
}
static id __attribute__((ns_returns_retained))
HGURL(id dev, SEL sel, NSURL *url, NSError **error) {
  id l = ((HGURLFn)HGURLIMP)(dev, sel, url, error);
  if (l && !HGInternal &&
      !HGRecord(l, [NSData dataWithContentsOfURL:url], url.path, nil) &&
      [(id<MTLLibrary>)l type] == MTLLibraryTypeDynamic)
    return HGFail(error, 23, @"Could not preserve file library AIR snapshot");
  return l;
}
static id __attribute__((ns_returns_retained))
HGData(id dev, SEL sel, dispatch_data_t data, NSError **error) {
  id l = ((HGURLFn)HGDataIMP)(dev, sel, data, error);
  if (l && !HGInternal) {
    const void *b = NULL;
    size_t n = 0;
    dispatch_data_t map = dispatch_data_create_map(data, &b, &n);
    NSData *bytes = [NSData dataWithBytes:b length:n];
    (void)map;
    if (!HGRecord(l, bytes, nil, nil) &&
        [(id<MTLLibrary>)l type] == MTLLibraryTypeDynamic)
      return HGFail(error, 23, @"Could not preserve data library AIR snapshot");
  }
  return l;
}
static id __attribute__((ns_returns_retained))
HGDynamicNew(id dev, SEL sel, id lib, NSError **error) {
  NSDictionary *r = objc_getAssociatedObject(lib, &HGLibKey);
  if (!r || [r[@"header"][@"type"] intValue] != 2)
    return HGFail(error, 24,
                  @"Dynamic API requires an inventoried dynamic AIR library");
  NSString *name = r[@"header"][@"install_name"];
  if (!name.length)
    return HGFail(error, 25, @"Missing dynamic install name");
  HGDynamic *d = [HGDynamic new];
  d.device = dev;
  d.installName = name;
  d.record = r;
  return d;
}
static id __attribute__((ns_returns_retained))
HGDynamicURL(id dev, SEL sel, NSURL *url, NSError **error) {
  id l = HGURL(dev, @selector(newLibraryWithURL:error:), url, error);
  return l ? HGDynamicNew(dev, @selector(newDynamicLibrary:error:), l, error)
           : nil;
}
static BOOL HGAddDeclared(NSDictionary *lib, NSMutableDictionary *pool,
                          NSError **error, NSUInteger depth) {
  if (depth > 8) {
    HGFail(error, 26, @"Dependency depth exceeded");
    return NO;
  }
  for (NSString *name in lib[@"header"][@"dependencies"]) {
    NSString *origin =
        lib[@"origin_url"] == NSNull.null ? nil : lib[@"origin_url"];
    NSString *path = nil;
    if ([name hasPrefix:@"@loader_path/"] && origin)
      path = [[origin stringByDeletingLastPathComponent]
          stringByAppendingPathComponent:[name substringFromIndex:13]];
    else if ([name hasPrefix:@"/"])
      path = name;
    else {
      HGFail(
          error, 27,
          @"Unresolved loader/executable/rpath origin in declared dependency");
      return NO;
    }
    NSData *b = [NSData dataWithContentsOfFile:path];
    NSDictionary *h = b ? HGHeader(b) : nil;
    if (!h || ![h[@"install_name"] isEqual:name] ||
        b.length > 16 * 1024 * 1024) {
      HGFail(error, 28, @"Missing or mismatched declared dynamic dependency");
      return NO;
    }
    NSString *hash = HGSHA(b);
    if (pool[hash])
      continue;
    NSDictionary *r = @{
      @"data" : b,
      @"sha256" : hash,
      @"origin_url" : path,
      @"header" : h,
      @"compile_dependencies" : @[]
    };
    pool[hash] = r;
    if (!HGAddDeclared(r, pool, error, depth + 1))
      return NO;
  }
  return YES;
}
static id __attribute__((ns_returns_retained))
HGPipeline(id dev, SEL sel, MTLComputePipelineDescriptor *desc,
           MTLPipelineOption opts, MTLComputePipelineReflection **reflection,
           NSError **error) {
  NSDictionary *fm =
      objc_getAssociatedObject(desc.computeFunction, &HGFunctionKey);
  NSDictionary *lib = fm[@"library"];
  NSArray *compile = lib[@"compile_dependencies"] ?: @[];
  NSArray *preloaded = desc.preloadedLibraries ?: @[];
  NSArray *declared = lib[@"header"][@"dependencies"] ?: @[];
  if (!compile.count && !preloaded.count && !declared.count)
    return ((HGPipelineFn)HGPipelineIMP)(dev, sel, desc, opts, reflection,
                                         error);
  if (!lib || desc.computeFunction.functionConstantsDictionary.count)
    return HGFail(error, 29,
                  @"Untracked or function-constant consumer unsupported by "
                  @"this stateless adapter");
  NSMutableDictionary *pool = [NSMutableDictionary new];
  NSMutableArray *preloadSHA = [NSMutableArray new];
  NSMutableArray *required = [NSMutableArray new];
  for (id obj in [compile arrayByAddingObjectsFromArray:preloaded]) {
    if (![obj isKindOfClass:HGDynamic.class] || [obj device] != dev)
      return HGFail(
          error, 30,
          @"Dependency belongs to a different device or implementation");
    HGDynamic *d = obj;
    pool[d.record[@"sha256"]] = d.record;
    [preloadSHA addObject:d.record[@"sha256"]];
    if ([compile containsObject:obj]) {
      if ([d.installName hasPrefix:@"@"] && lib[@"origin_url"] == NSNull.null)
        return HGFail(error, 31,
                      @"Relative install name cannot resolve in a "
                      @"runtime-source consumer with no URL");
      [required addObject:d.installName];
    }
  }
  if (!HGAddDeclared(lib, pool, error, 0))
    return nil;
  for (NSDictionary *d in pool.allValues)
    if (!HGAddDeclared(d, pool, error, 0))
      return nil;
  if (pool.count > 16)
    return HGFail(error, 32, @"Dependency count exceeded");
  NSMutableArray *dependencies = [NSMutableArray new];
  for (NSString *k in
       [[pool allKeys] sortedArrayUsingSelector:@selector(compare:)])
    [dependencies addObject:HGWire(pool[k])];
  NSDictionary *request = @{
    @"schema" : @1,
    @"recipe" : @(HGRecipeID),
    @"consumer" : HGWire(lib),
    @"libraries" : dependencies,
    @"preloaded_sha256" : preloadSHA,
    @"compile_install_names" : required,
    @"function_name" : fm[@"name"],
    @"origin_semantics" : @"guest-resolved-file-urls"
  };
  NSData *req = [NSJSONSerialization dataWithJSONObject:request
                                                options:NSJSONWritingSortedKeys
                                                  error:nil];
  if (req.length > 24 * 1024 * 1024)
    return HGFail(error, 38,
                  @"Dependency request exceeds the supported byte limit");
  NSString *key = HGSHA(req);
  NSString *requestPath = [[HGRoot stringByAppendingPathComponent:@"requests"]
      stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
  [req writeToFile:requestPath options:NSDataWritingAtomic error:nil];
  NSString *base = [[HGRoot stringByAppendingPathComponent:@"ready"]
      stringByAppendingPathComponent:key];
  if (![NSFileManager.defaultManager
          fileExistsAtPath:[base stringByAppendingString:@".json"]] &&
      !HGFetchReady(key, req, base, error))
    return nil;
  NSData *receiptBytes =
      [NSData dataWithContentsOfFile:[base stringByAppendingString:@".json"]];
  NSDictionary *receipt =
      receiptBytes ? [NSJSONSerialization JSONObjectWithData:receiptBytes
                                                     options:0
                                                       error:nil]
                   : nil;
  NSData *binary = [NSData
      dataWithContentsOfFile:[base stringByAppendingString:@".metallib"]];
  if (receipt && (![receipt[@"request_sha256"] isEqual:key] ||
                  ![receipt[@"recipe"] isEqual:request[@"recipe"]]))
    return HGFail(error, 34, @"Closure receipt identity mismatch");
  if ([receipt[@"status"] isEqual:@"rejected"])
    return HGFail(error, 37, receipt[@"error"] ?: @"Compiler rejected closure");
  if (!receipt || !binary)
    return HGFail(
        error, 33,
        [NSString stringWithFormat:@"Closure pending; request %@", key]);
  if (![receipt[@"request_sha256"] isEqual:key] ||
      ![receipt[@"recipe"] isEqual:request[@"recipe"]] ||
      ![receipt[@"output_sha256"] isEqual:HGSHA(binary)])
    return HGFail(error, 34, @"Closure receipt identity mismatch");
  if (!HGHeader(binary))
    return HGFail(error, 35, @"Invalid closure output");
  HGInternal = YES;
  NSError *loadError = nil;
  id<MTLLibrary> closed = ((HGURLFn)HGURLIMP)(
      dev, @selector(newLibraryWithURL:error:),
      [NSURL fileURLWithPath:[base stringByAppendingString:@".metallib"]],
      &loadError);
  HGInternal = NO;
  if (!closed) {
    if (error)
      *error = loadError;
    return nil;
  }
  id<MTLFunction> f = [closed newFunctionWithName:fm[@"name"]];
  if (!f)
    return HGFail(error, 36, @"Closure function missing");
  MTLComputePipelineDescriptor *copy = [desc copy];
  copy.computeFunction = f;
  copy.preloadedLibraries = @[];
  id pipeline =
      ((HGPipelineFn)HGPipelineIMP)(dev, sel, copy, opts, reflection, error);
  if (pipeline)
    objc_setAssociatedObject(
        pipeline, &HGFunctionKey,
        @{@"request" : key, @"output_sha256" : receipt[@"output_sha256"]},
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return pipeline;
}
static void HGSourceAsync(id dev, SEL sel, NSString *source,
                          MTLCompileOptions *options,
                          void (^callback)(id<MTLLibrary>, NSError *)) {
  NSString *saved = [source copy];
  MTLCompileOptions *savedOptions = [options copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSError *error = nil;
      id l = HGSource(dev, @selector(newLibraryWithSource:options:error:),
                      saved, savedOptions, &error);
      callback(l, error);
    }
  });
}
static void HGPipelineAsync(id dev, SEL sel, MTLComputePipelineDescriptor *desc,
                            MTLPipelineOption options,
                            void (^callback)(id<MTLComputePipelineState>,
                                             MTLComputePipelineReflection *,
                                             NSError *)) {
  MTLComputePipelineDescriptor *saved = [desc copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSError *error = nil;
      MTLComputePipelineReflection *reflection = nil;
      id p = HGPipeline(
          dev,
          @selector(
              newComputePipelineStateWithDescriptor:options:reflection:error:),
          saved, options, &reflection, &error);
      callback(p, reflection, error);
    }
  });
}
static id __attribute__((ns_returns_retained))
HGPipelineFunction(id dev, SEL sel, id<MTLFunction> function, NSError **error) {
  MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
  d.computeFunction = function;
  return HGPipeline(
      dev,
      @selector(
          newComputePipelineStateWithDescriptor:options:reflection:error:),
      d, MTLPipelineOptionNone, NULL, error);
}
static void HGPipelineFunctionAsync(
    id dev, SEL sel, id<MTLFunction> function,
    void (^callback)(id<MTLComputePipelineState>, NSError *)) {
  MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
  d.computeFunction = function;
  HGPipelineAsync(
      dev,
      @selector(
          newComputePipelineStateWithDescriptor:options:completionHandler:),
      d, MTLPipelineOptionNone, ^(id p, id r, NSError *e) {
        callback(p, e);
      });
}
static id __attribute__((ns_returns_retained)) HGPipelineFunctionOptions(
    id dev, SEL sel, id<MTLFunction> f, MTLPipelineOption opts,
    MTLComputePipelineReflection **reflection, NSError **error) {
  MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
  d.computeFunction = f;
  return HGPipeline(
      dev,
      @selector(
          newComputePipelineStateWithDescriptor:options:reflection:error:),
      d, opts, reflection, error);
}
static void HGPipelineFunctionOptionsAsync(
    id dev, SEL sel, id<MTLFunction> f, MTLPipelineOption opts,
    void (^callback)(id<MTLComputePipelineState>,
                     MTLComputePipelineReflection *, NSError *)) {
  MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new];
  d.computeFunction = f;
  HGPipelineAsync(
      dev,
      @selector(
          newComputePipelineStateWithDescriptor:options:completionHandler:),
      d, opts, callback);
}
static BOOL HGRenderUsesCompatibility(MTLRenderPipelineDescriptor *d) {
  for (id l in [(d.vertexPreloadedLibraries ?: @[
       ]) arrayByAddingObjectsFromArray:d.fragmentPreloadedLibraries ?: @[]])
    if ([l isKindOfClass:HGDynamic.class])
      return YES;
  for (id f in @[
         d.vertexFunction ?: NSNull.null, d.fragmentFunction ?: NSNull.null
       ]) {
    NSDictionary *r = objc_getAssociatedObject(f, &HGFunctionKey)[@"library"];
    if ([r[@"compile_dependencies"] count] ||
        [r[@"header"][@"dependencies"] count])
      return YES;
  }
  return NO;
}
static id __attribute__((ns_returns_retained))
HGRenderBasic(id dev, SEL sel, MTLRenderPipelineDescriptor *d, NSError **e) {
  if (HGRenderUsesCompatibility(d))
    return HGFail(e, 46,
                  @"Render dynamic libraries are unsupported by this "
                  @"compute-only adapter");
  return ((HGURLFn)HGRenderBasicIMP)(dev, sel, d, e);
}
static id __attribute__((ns_returns_retained))
HGRenderOptions(id dev, SEL sel, MTLRenderPipelineDescriptor *d,
                MTLPipelineOption o, MTLRenderPipelineReflection **r,
                NSError **e) {
  if (HGRenderUsesCompatibility(d))
    return HGFail(e, 46,
                  @"Render dynamic libraries are unsupported by this "
                  @"compute-only adapter");
  return ((HGPipelineFn)HGRenderOptionsIMP)(dev, sel, d, o, r, e);
}
static void HGRenderAsync(id dev, SEL sel, MTLRenderPipelineDescriptor *d,
                          void (^callback)(id<MTLRenderPipelineState>,
                                           NSError *)) {
  if (!HGRenderUsesCompatibility(d)) {
    ((void (*)(id, SEL, id, id))HGRenderAsyncIMP)(dev, sel, d, callback);
    return;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *e = nil;
    HGFail(&e, 46,
           @"Render dynamic libraries are unsupported by this compute-only "
           @"adapter");
    callback(nil, e);
  });
}
static void HGRenderAsyncOptions(id dev, SEL sel,
                                 MTLRenderPipelineDescriptor *d,
                                 MTLPipelineOption o,
                                 void (^callback)(id<MTLRenderPipelineState>,
                                                  MTLRenderPipelineReflection *,
                                                  NSError *)) {
  if (!HGRenderUsesCompatibility(d)) {
    ((void (*)(id, SEL, id, NSUInteger, id))HGRenderAsyncOptionsIMP)(
        dev, sel, d, o, callback);
    return;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *e = nil;
    HGFail(&e, 46,
           @"Render dynamic libraries are unsupported by this compute-only "
           @"adapter");
    callback(nil, nil, e);
  });
}
static IMP HGReplace(Class c, SEL s, IMP i) {
  Method m = class_getInstanceMethod(c, s);
  IMP old = method_getImplementation(m);
  class_replaceMethod(c, s, i, method_getTypeEncoding(m));
  return old;
}
static BOOL HGYes(id d, SEL s) { return YES; }
static BOOL HGNo(id d, SEL s) { return NO; }
static void HGInstall(id<MTLDevice> d, NSString *root) {
  static Class installed = nil;
  @synchronized(HGDynamic.class) {
    if (installed)
      return;
    installed = [d class];
    HGRoot = root;
    for (NSString *n in @[ @"requests", @"ready" ])
      [NSFileManager.defaultManager
                createDirectoryAtPath:[root stringByAppendingPathComponent:n]
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
    Class c = [d class];
    HGSourceIMP = HGReplace(c, @selector(newLibraryWithSource:options:error:),
                            (IMP)HGSource);
    HGURLIMP = HGReplace(c, @selector(newLibraryWithURL:error:), (IMP)HGURL);
    HGDataIMP = HGReplace(c, @selector(newLibraryWithData:error:), (IMP)HGData);
    HGDynamicIMP =
        HGReplace(c, @selector(newDynamicLibrary:error:), (IMP)HGDynamicNew);
    HGReplace(c, @selector(newDynamicLibraryWithURL:error:), (IMP)HGDynamicURL);
    HGPipelineIMP = HGReplace(
        c,
        @selector(
            newComputePipelineStateWithDescriptor:options:reflection:error:),
        (IMP)HGPipeline);
    HGReplace(c, @selector(newLibraryWithSource:options:completionHandler:),
              (IMP)HGSourceAsync);
    HGReplace(
        c,
        @selector(
            newComputePipelineStateWithDescriptor:options:completionHandler:),
        (IMP)HGPipelineAsync);
    HGReplace(c, @selector(newComputePipelineStateWithFunction:error:),
              (IMP)HGPipelineFunction);
    HGReplace(c,
              @selector(newComputePipelineStateWithFunction:completionHandler:),
              (IMP)HGPipelineFunctionAsync);
    HGReplace(
        c,
        @selector(
            newComputePipelineStateWithFunction:options:reflection:error:),
        (IMP)HGPipelineFunctionOptions);
    HGReplace(
        c,
        @selector(
            newComputePipelineStateWithFunction:options:completionHandler:),
        (IMP)HGPipelineFunctionOptionsAsync);
    HGRenderBasicIMP =
        HGReplace(c, @selector(newRenderPipelineStateWithDescriptor:error:),
                  (IMP)HGRenderBasic);
    HGRenderOptionsIMP = HGReplace(
        c,
        @selector(
            newRenderPipelineStateWithDescriptor:options:reflection:error:),
        (IMP)HGRenderOptions);
    HGRenderAsyncIMP = HGReplace(
        c, @selector(newRenderPipelineStateWithDescriptor:completionHandler:),
        (IMP)HGRenderAsync);
    HGRenderAsyncOptionsIMP = HGReplace(
        c,
        @selector(
            newRenderPipelineStateWithDescriptor:options:completionHandler:),
        (IMP)HGRenderAsyncOptions);
    HGReplace(c, @selector(supportsDynamicLibraries), (IMP)HGYes);
    HGReplace(c, @selector(supportsRenderDynamicLibraries), (IMP)HGNo);
    if ([d respondsToSelector:NSSelectorFromString(
                                  @"supportsStatefulDynamicLibraries")])
      HGReplace(c, NSSelectorFromString(@"supportsStatefulDynamicLibraries"),
                (IMP)HGNo);
  }
}
