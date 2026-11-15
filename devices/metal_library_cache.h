/* Worker-confined, exact-byte Metal library reuse. No persistence or failed-entry cache. */
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "metal4_pipeline.h"

@interface HvMetalLibraryEntry : NSObject
@property(nonatomic, strong) NSData *key;
@property(nonatomic, strong) id<MTLLibrary> library;
@property(nonatomic, strong) id<MTLFunction> firstFunction;
@end
@implementation HvMetalLibraryEntry
@end

@interface HvMetalLibraryCache : NSObject {
    NSMutableDictionary<NSData *, HvMetalLibraryEntry *> *_libraries;
    NSMutableArray<HvMetalLibraryEntry *> *_order; /* least recently used first */
    NSUInteger _maxBytes, _maxEntries;
}
@property(nonatomic, readonly) NSUInteger retainedBytes;
@property(nonatomic, readonly) NSUInteger count;
@property(nonatomic, readonly) NSUInteger admissionBytes;
@property(nonatomic, readonly) NSUInteger admissionEntries;
@property(nonatomic, readonly) uint64_t hits;
@property(nonatomic, readonly) uint64_t loads;
@property(nonatomic, readonly) uint64_t functionHits;
@property(nonatomic, readonly) uint64_t functionBuilds;
- (instancetype)initWithMaxBytes:(NSUInteger)bytes entries:(NSUInteger)entries;
- (id<MTLLibrary>)libraryForData:(NSData *)data loader:(id<MTLLibrary>(^)(void))loader;
- (id<MTLFunction>)firstFunctionForData:(NSData *)data loader:(id<MTLLibrary>(^)(void))loader;
- (void)trim;
- (void)setAdmissionBytes:(NSUInteger)bytes entries:(NSUInteger)entries;
@end

@implementation HvMetalLibraryCache
- (instancetype)initWithMaxBytes:(NSUInteger)bytes entries:(NSUInteger)entries {
    if ((self = [super init])) {
        _libraries = [NSMutableDictionary new]; _order = [NSMutableArray new];
        _maxBytes = bytes; _maxEntries = entries;
    }
    return self;
}
- (NSUInteger)count { return _libraries.count; }
- (NSUInteger)admissionBytes { return _maxBytes; }
- (NSUInteger)admissionEntries { return _maxEntries; }
- (void)trim { [_libraries removeAllObjects]; [_order removeAllObjects]; _retainedBytes = 0; }
- (void)setAdmissionBytes:(NSUInteger)bytes entries:(NSUInteger)entries {
    _maxBytes = bytes; _maxEntries = entries;
    while (_order.count && (_order.count > entries || _retainedBytes > bytes)) {
        HvMetalLibraryEntry *old = _order.firstObject;
        _retainedBytes -= old.key.length;
        [_libraries removeObjectForKey:old.key]; [_order removeObjectAtIndex:0];
    }
}
- (HvMetalLibraryEntry *)entryForData:(NSData *)data loader:(id<MTLLibrary>(^)(void))loader {
    HvMetalLibraryEntry *cached = _libraries[data];
    if (cached) {
        _hits++;
        /* Bounded by the current resource budget; compare entry identity. */
        [_order removeObjectIdenticalTo:cached]; [_order addObject:cached];
        return cached;
    }
    _loads++;
    id<MTLLibrary> library = loader();
    if (!library) return nil;
    HvMetalLibraryEntry *entry = [HvMetalLibraryEntry new]; entry.library = library;
    if (!data.length || data.length > _maxBytes || !_maxEntries) return entry;
    while (_order.count && (_order.count >= _maxEntries || _retainedBytes > _maxBytes - data.length)) {
        HvMetalLibraryEntry *old = _order.firstObject;
        _retainedBytes -= old.key.length;
        [_libraries removeObjectForKey:old.key]; [_order removeObjectAtIndex:0];
    }
    entry.key = [data copy]; // mutable caller buffers may be reused after lookup
    _libraries[entry.key] = entry; [_order addObject:entry]; _retainedBytes += entry.key.length;
    return entry;
}
- (id<MTLLibrary>)libraryForData:(NSData *)data loader:(id<MTLLibrary>(^)(void))loader {
    return [self entryForData:data loader:loader].library;
}
- (id<MTLFunction>)firstFunctionForData:(NSData *)data loader:(id<MTLLibrary>(^)(void))loader {
    HvMetalLibraryEntry *entry = [self entryForData:data loader:loader];
    if (!entry) return nil;
    if (entry.firstFunction) { _functionHits++; return entry.firstFunction; }
    NSString *name = entry.library.functionNames.firstObject;
    if (!name) return nil;
    _functionBuilds++;
    /* The guest asks for the first, unspecialized function. No function constants,
       task references or mutable pipeline state enter this exact-binary cache. */
    entry.firstFunction = [entry.library newFunctionWithName:name];
    hv_metal4_note_function(entry.firstFunction,entry.library);
    return entry.firstFunction; // nil failures retry; bypass entries are not retained
}
@end
