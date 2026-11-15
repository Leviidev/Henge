#import "metal_library_cache.h"
#include <assert.h>
#include <stdio.h>
#include "../host/resource_policy.h"

int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    NSData *binary = [NSData dataWithContentsOfFile:@(argv[1])]; assert(binary);
    __block unsigned calls = 0;
    __block id<MTLLibrary> actual;
    id<MTLLibrary>(^loader)(void) = ^id<MTLLibrary> {
        calls++;
        dispatch_data_t d = dispatch_data_create(binary.bytes,binary.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *error=nil;
        actual=[device newLibraryWithData:d error:&error]; assert(actual && !error);
        return actual;
    };
    HvMetalLibraryCache *cache = [[HvMetalLibraryCache alloc] initWithMaxBytes:binary.length * 2 entries:2];
    id<MTLLibrary> first=[cache libraryForData:binary loader:loader];
    assert(first && calls==1);
    assert([cache libraryForData:[binary mutableCopy] loader:loader]==first && calls==1 && cache.hits==1);
    // Deliberately use tiny keys with a real loader to isolate exact-key and eviction behavior.
    NSMutableData *key=[NSMutableData dataWithBytes:"abc" length:3];
    [cache libraryForData:key loader:loader];
    ((char *)key.mutableBytes)[0]='x';
    [cache libraryForData:key loader:loader];
    assert(calls==3 && cache.count==2 && cache.retainedBytes==6);
    [cache libraryForData:[NSData dataWithBytes:"abc" length:3] loader:loader];
    assert(calls==3); // original key was copied, not mutated
    [cache libraryForData:binary loader:loader]; assert(calls==4 && cache.count==2);
    HvMetalLibraryCache *small=[[HvMetalLibraryCache alloc] initWithMaxBytes:2 entries:2];
    [small libraryForData:binary loader:loader];[small libraryForData:binary loader:loader];
    assert(calls==6 && !small.count && !small.retainedBytes);
    NSData *empty=[NSData data];
    [small libraryForData:empty loader:loader]; assert(!small.count);
    __block unsigned failed=0;
    id<MTLLibrary>(^failure)(void)=^id<MTLLibrary>{failed++;return nil;};
    NSData *k=[NSData dataWithBytes:"z" length:1];
    assert(![small libraryForData:k loader:failure]);assert(![small libraryForData:k loader:failure]);
    assert(failed==2 && !small.count); // errors retry rather than poisoning cache
    assert([first newFunctionWithName:@"screen_v"]); // evicted libraries held by users stay alive
    [cache trim]; assert(!cache.count && !cache.retainedBytes);
    [cache setAdmissionBytes:0 entries:0];
    [cache libraryForData:binary loader:loader]; assert(!cache.count);
    [cache setAdmissionBytes:binary.length entries:1];
    [cache libraryForData:binary loader:loader]; assert(cache.count==1 && cache.retainedBytes==binary.length);
    [cache setAdmissionBytes:0 entries:0]; assert(!cache.count && !cache.retainedBytes);
    assert([first newFunctionWithName:@"screen_v"]); // pressure purge cannot invalidate a live owner
    HvMetalLibraryCache *lru=[[HvMetalLibraryCache alloc] initWithMaxBytes:32 entries:2];
    NSData *a=[@"a" dataUsingEncoding:NSUTF8StringEncoding], *b=[@"b" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *c=[@"c" dataUsingEncoding:NSUTF8StringEncoding];
    unsigned start=calls;
    [lru libraryForData:a loader:loader];[lru libraryForData:b loader:loader];
    [lru libraryForData:a loader:loader];[lru libraryForData:c loader:loader];
    [lru libraryForData:a loader:loader];assert(calls==start+3); // hot a survives; FIFO would evict it
    [lru setAdmissionBytes:32 entries:1];
    [lru libraryForData:a loader:loader];assert(calls==start+3 && lru.count==1);
    [lru setAdmissionBytes:32 entries:1]; // repeated pressure cannot throw away an in-budget entry
    [lru libraryForData:a loader:loader];assert(calls==start+3);
    [lru libraryForData:b loader:loader];assert(calls==start+4);

    HvMetalLibraryCache *functions=[[HvMetalLibraryCache alloc] initWithMaxBytes:binary.length entries:1];
    id<MTLFunction> function=[functions firstFunctionForData:binary loader:loader];
    assert(function && functions.functionBuilds==1);
    start=calls;
    for (unsigned i=0;i<100;i++)
        assert([functions firstFunctionForData:[binary mutableCopy] loader:loader]==function);
    assert(calls==start && functions.functionBuilds==1 && functions.functionHits==100);
    [functions setAdmissionBytes:0 entries:0];
    assert(!functions.count && !functions.retainedBytes);
    assert([functions firstFunctionForData:binary loader:loader]);
    assert([functions firstFunctionForData:binary loader:loader]);
    assert(calls==start+2 && functions.functionBuilds==3); // no hidden function cache when admission is zero
    [functions setAdmissionBytes:binary.length entries:1];
    assert([functions firstFunctionForData:binary loader:loader]);
    assert(function.name.length); // purge cannot invalidate a guest-retained function
    [functions trim];
    assert(![functions firstFunctionForData:binary loader:failure]);
    assert(![functions firstFunctionForData:binary loader:failure]);
    assert(failed==4 && !functions.count); // library failures retry through the function path too
    HvResourceBudget roomy=hv_resource_budget_profile(4ull<<30,0,1);
    HvMetalLibraryCache *working=[[HvMetalLibraryCache alloc]initWithMaxBytes:roomy.library_bytes entries:roomy.library_entries];
    unsigned before=calls;
    for(unsigned pass=0;pass<2;pass++)for(uint32_t i=0;i<96;i++) {
        NSData *identity=[NSData dataWithBytes:&i length:sizeof i];
        assert([working libraryForData:identity loader:loader]);
    }
    assert(calls==before+96 && working.count==96);
    HvResourceBudget warned=hv_resource_budget_profile(4ull<<30,1,1);
    [working setAdmissionBytes:warned.library_bytes entries:warned.library_entries];
    assert(working.count==8 && first.functionNames.count); // live retained library remains valid
    puts("M4 library cache:96 exact keys/96 loads over192 requests; pressure returns to8 hot entries");
    puts("Metal library cache: exact-byte LRU, immutable keys, hot-budget retention, 100 function reuses/one build, bounded bypass, failed retry and live-owner safety passed");
    return 0;
} }
