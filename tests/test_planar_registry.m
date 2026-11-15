#import "planar_registry.h"
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
int main(void){@autoreleasepool{
 uint8_t desc[1024]={0};uint32_t pages[3]={0x1001,0x2001,0x3001};desc[0x3e]=2;
 NSData *key=hv_planar_identity(desc,pages,3);assert(key);
 assert([key isEqual:hv_planar_identity(desc,pages,3)]);
 pages[2]^=0x4000;assert(![key isEqual:hv_planar_identity(desc,pages,3)]);pages[2]^=0x4000;
 desc[0x60]=1;assert(![key isEqual:hv_planar_identity(desc,pages,3)]);desc[0x60]=0;
 desc[0x80+0x30]=16;assert(![key isEqual:hv_planar_identity(desc,pages,3)]);desc[0x80+0x30]=0;
 IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{(__bridge id)kIOSurfaceWidth:@4,(__bridge id)kIOSurfaceHeight:@4,(__bridge id)kIOSurfaceBytesPerElement:@4,(__bridge id)kIOSurfaceBytesPerRow:@64,(__bridge id)kIOSurfacePixelFormat:@(0x42475241u)});assert(surface);
 NSMutableDictionary *registry=[NSMutableDictionary new];__block unsigned allocations=0;BOOL reused;
 HvPlanarEntry *(^factory)(void)=^HvPlanarEntry *{allocations++;HvPlanarEntry *e=[[HvPlanarEntry alloc] initWithSurface:surface];e->count=2;e->row[1]=64;return e;};
 HvPlanarEntry *first=hv_planar_resolve(registry,key,factory,&reused);assert(first&&!reused&&allocations==1);
 IOSurfaceLock(surface,0,NULL);((uint32_t*)IOSurfaceGetBaseAddress(surface))[0]=0xff123456;IOSurfaceUnlock(surface,0,NULL);
 for(int i=0;i<1000;i++){HvPlanarEntry *e=hv_planar_resolve(registry,key,factory,&reused);assert(e==first&&reused&&e->row[1]==64);}
 assert(allocations==1&&((uint32_t*)IOSurfaceGetBaseAddress(first->surface))[0]==0xff123456);
 id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
 MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
 id<MTLTexture> texture=[device newTextureWithDescriptor:td iosurface:first->surface plane:0];assert(texture);
 uint32_t pixels[16];[texture getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];assert(pixels[0]==0xff123456);
 [registry removeAllObjects];assert(texture.width==4&&IOSurfaceGetWidth(first->surface)==4);
 NSData *bad=[NSData dataWithBytes:"failure" length:7];assert(!hv_planar_resolve(registry,bad,^HvPlanarEntry *{return nil;},&reused));assert(!registry[bad]);
 first->mapping_users=2;HvPlanarLink *link=[HvPlanarLink new];link.entry=first;registry[key]=link;
 hv_planar_release_mapping(registry,key,first);assert(hv_planar_lookup(registry,key)==first&&first->mapping_users==1);
 hv_planar_release_mapping(registry,key,first);assert(hv_planar_lookup(registry,key)==first && !first->mapping_users); // texture/surface owners still live
 HvPlanarEntry *newer=factory();HvPlanarLink *replacement=[HvPlanarLink new];replacement.entry=newer;registry[key]=replacement;first->mapping_users=1;
 hv_planar_release_mapping(registry,key,first);assert(hv_planar_lookup(registry,key)==newer); // stale mapping cannot erase a replacement
 NSData *ephemeral=[@"ephemeral" dataUsingEncoding:NSUTF8StringEncoding];
 __weak HvPlanarEntry *weakEntry;
 @autoreleasepool { HvPlanarEntry *entry=hv_planar_resolve(registry,ephemeral,factory,&reused);weakEntry=entry;assert(entry); }
 assert(!weakEntry);hv_planar_prune(registry);assert(!registry[ephemeral]);
 CFRelease(surface);
 puts("planar registry: full page/layout identity, 1001 aliases -> 1 allocation, preserved host pixels, Metal texture view, retained ownership, failed-create retry, weak identity follows texture ownership and stale-unmap guard passed");
}}
