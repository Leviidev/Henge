#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>

/* Metadata belongs to one pooled job/table. The native argument table, not
   this owner, is passed to Metal. A job cannot be borrowed again until GPU
   feedback has retired it, so clearing never races an in-flight encoder. */
API_AVAILABLE(macos(26.0),ios(26.0))
@interface HvMetal4Arguments : NSObject {
    uint32_t _buffers;
    uint64_t _textures[2];
    uint16_t _samplers;
}
@property(nonatomic,readonly) id<MTL4ArgumentTable> table;
- (instancetype)initWithTable:(id<MTL4ArgumentTable>)table;
- (void)clearForReuse;
- (void)setAddress:(MTLGPUAddress)address atIndex:(NSUInteger)index;
- (void)setAddress:(MTLGPUAddress)address attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index;
- (void)setTexture:(MTLResourceID)texture atIndex:(NSUInteger)index;
- (void)setSamplerState:(MTLResourceID)sampler atIndex:(NSUInteger)index;
@end

@implementation HvMetal4Arguments
- (instancetype)initWithTable:(id<MTL4ArgumentTable>)table {
    if(!table || !(self=[super init]))return nil;
    _table=table;
    /* Do not assume a newly allocated Metal table is initialised. Establish
       exactly the same zero baseline as the original full-clear path once. */
    for(NSUInteger i=0;i<31;i++)[_table setAddress:0 attributeStride:0 atIndex:i];
    MTLResourceID zero={0};
    for(NSUInteger i=0;i<128;i++)[_table setTexture:zero atIndex:i];
    for(NSUInteger i=0;i<16;i++)[_table setSamplerState:zero atIndex:i];
    return self;
}
- (void)clearForReuse {
    for(uint32_t used=_buffers;used;used&=used-1)
        [_table setAddress:0 attributeStride:0 atIndex:(NSUInteger)__builtin_ctz(used)];
    MTLResourceID zero={0};
    for(unsigned half=0;half<2;half++)
        for(uint64_t used=_textures[half];used;used&=used-1)
            [_table setTexture:zero atIndex:64*half+(NSUInteger)__builtin_ctzll(used)];
    for(uint32_t used=_samplers;used;used&=used-1)
        [_table setSamplerState:zero atIndex:(NSUInteger)__builtin_ctz(used)];
    _buffers=0;_textures[0]=_textures[1]=0;_samplers=0;
}
- (void)setAddress:(MTLGPUAddress)address atIndex:(NSUInteger)index {
    if(index>=31){[NSException raise:NSRangeException format:@"Metal4 buffer index"];return;}
    _buffers|=1u<<index;[_table setAddress:address atIndex:index];
}
- (void)setAddress:(MTLGPUAddress)address attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index {
    if(index>=31){[NSException raise:NSRangeException format:@"Metal4 buffer index"];return;}
    _buffers|=1u<<index;[_table setAddress:address attributeStride:stride atIndex:index];
}
- (void)setTexture:(MTLResourceID)texture atIndex:(NSUInteger)index {
    if(index>=128){[NSException raise:NSRangeException format:@"Metal4 texture index"];return;}
    _textures[index/64]|=1ull<<(index%64);[_table setTexture:texture atIndex:index];
}
- (void)setSamplerState:(MTLResourceID)sampler atIndex:(NSUInteger)index {
    if(index>=16){[NSException raise:NSRangeException format:@"Metal4 sampler index"];return;}
    _samplers|=(uint16_t)(1u<<index);[_table setSamplerState:sampler atIndex:index];
}
@end
