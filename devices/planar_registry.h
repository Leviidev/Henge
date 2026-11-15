/* Exact backing/layout identity. This is not a pixel-content hash or dirty tracker. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#include <stdint.h>
#include <string.h>

@interface HvPlanarEntry:NSObject { @public
    IOSurfaceRef surface;
    BOOL shared_pages;
    id<MTLBuffer> pages;
    uint32_t count, mapping_users;
    NSMutableData *hashes;
    uint64_t from[4],row[4],height[4];
}
- (instancetype)initWithSurface:(IOSurfaceRef)value;
@end
@implementation HvPlanarEntry
- (instancetype)initWithSurface:(IOSurfaceRef)value { if((self=[super init])){surface=value?(IOSurfaceRef)CFRetain(value):NULL;hashes=[NSMutableData dataWithLength:4*sizeof(uint64_t)];}return self; }
- (void)dealloc { if(surface)CFRelease(surface); }
@end
static NSData *hv_planar_identity(const uint8_t *desc,const uint32_t *pages,uint64_t n) {
    if(!pages || n>SIZE_MAX/sizeof(uint32_t))return nil;
    NSMutableData *key=[NSMutableData data];
    const unsigned offsets[]={4,0x18,0x20,0x28,0x30,0x60};
    const unsigned widths[]={4,8,8,8,8,4};
    for(unsigned i=0;i<6;i++)[key appendBytes:desc+offsets[i] length:widths[i]];
    [key appendBytes:desc+0x3e length:1];
    for(unsigned i=0;i<desc[0x3e] && i<4;i++) {
        const uint8_t *p=desc+0x80+i*0x80;
        const unsigned fields[]={8,0x18,0x20,0x28,0x30,0x38};
        for(unsigned j=0;j<6;j++)[key appendBytes:p+fields[j] length:j==5?2:8];
    }
    [key appendBytes:pages length:(NSUInteger)n*sizeof(uint32_t)];
    return [key copy];
}
/* Weak identity metadata follows real surface/texture ownership. Unmapping a
   guest address must not split a still-live GPU allocation into two backends. */
@interface HvPlanarLink:NSObject
@property(nonatomic,weak) HvPlanarEntry *entry;
@end
@implementation HvPlanarLink
@end
static HvPlanarEntry *hv_planar_lookup(NSMutableDictionary *registry,NSData *key) {
    return key ? ((HvPlanarLink *)registry[key]).entry : nil;
}
static void hv_planar_prune(NSMutableDictionary *registry) {
    for(NSData *key in registry.allKeys)if(!hv_planar_lookup(registry,key))[registry removeObjectForKey:key];
}
static HvPlanarEntry *hv_planar_resolve(NSMutableDictionary *registry,
       NSData *key,HvPlanarEntry *(^create)(void),BOOL *reused) {
    HvPlanarEntry *entry=hv_planar_lookup(registry,key);
    *reused=entry!=nil;
    if(entry)return entry;
    if(!(registry.count%64))hv_planar_prune(registry);
    entry=create();
    if(entry && key){HvPlanarLink *link=[HvPlanarLink new];link.entry=entry;registry[key]=link;}
    return entry;
}

/* Serial replay-worker ownership. Evicted identities cannot release a newer
   entry for the same pages, and live texture users retain their own IOSurface. */
static void hv_planar_release_mapping(NSMutableDictionary *registry,
                                      NSData *key,HvPlanarEntry *entry) {
    (void)registry;(void)key;
    if(entry && entry->mapping_users)entry->mapping_users--;
    /* The weak entry disappears only when texture/surface owners are gone. */
}
