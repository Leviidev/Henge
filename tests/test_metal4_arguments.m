#import <Foundation/Foundation.h>
#include "../devices/metal4_arguments.h"
#include <assert.h>
#include <string.h>

/* Recording table exercises the production owner/reset code without claiming
   Metal4 GPU execution on the cloud runner's paravirtual GPU. */
@interface ArgumentRecorder : NSObject {
@public
    uint64_t addresses[31],strides[31],textures[128],samplers[16];
    unsigned calls;
}
@end
@implementation ArgumentRecorder
- (void)setAddress:(MTLGPUAddress)a atIndex:(NSUInteger)i {assert(i<31);addresses[i]=a;calls++;}
- (void)setAddress:(MTLGPUAddress)a attributeStride:(NSUInteger)s atIndex:(NSUInteger)i {assert(i<31);addresses[i]=a;strides[i]=s;calls++;}
- (void)setTexture:(MTLResourceID)t atIndex:(NSUInteger)i {assert(i<128);memcpy(&textures[i],&t,8);calls++;}
- (void)setSamplerState:(MTLResourceID)t atIndex:(NSUInteger)i {assert(i<16);memcpy(&samplers[i],&t,8);calls++;}
@end
static void fullClear(ArgumentRecorder *t) {
    MTLResourceID zero={0};
    for(unsigned i=0;i<31;i++)[t setAddress:0 attributeStride:0 atIndex:i];
    for(unsigned i=0;i<128;i++)[t setTexture:zero atIndex:i];
    for(unsigned i=0;i<16;i++)[t setSamplerState:zero atIndex:i];
}
static void equal(ArgumentRecorder *a,ArgumentRecorder *b) {
    assert(!memcmp(a->addresses,b->addresses,sizeof a->addresses));
    assert(!memcmp(a->strides,b->strides,sizeof a->strides));
    assert(!memcmp(a->textures,b->textures,sizeof a->textures));
    assert(!memcmp(a->samplers,b->samplers,sizeof a->samplers));
}
int main(void){@autoreleasepool{
    ArgumentRecorder *native=[ArgumentRecorder new],*reference=[ArgumentRecorder new];
    /* Begin with dirty memory: first-use initialization is mandatory. */
    memset(native->addresses,0xff,sizeof native->addresses);
    memset(native->strides,0xff,sizeof native->strides);
    memset(native->textures,0xff,sizeof native->textures);
    memset(native->samplers,0xff,sizeof native->samplers);
    HvMetal4Arguments *owner=[[HvMetal4Arguments alloc]initWithTable:(id)native];
    assert(owner.table==(id)native&&native->calls==175);fullClear(reference);equal(native,reference);
    uint64_t bits=77;MTLResourceID resource;memcpy(&resource,&bits,8);
    [owner setAddress:100 attributeStride:16 atIndex:30];
    [owner setTexture:resource atIndex:127];[owner setTexture:resource atIndex:127];
    [owner setSamplerState:resource atIndex:15];
    unsigned before=native->calls;[owner clearForReuse];
    assert(native->calls-before==3);equal(native,reference);
    before=native->calls;[owner clearForReuse];assert(native->calls==before);
    uint32_t random=0x749abe01;
    for(unsigned cycle=0;cycle<1000;cycle++) {
        for(unsigned update=0;update<50;update++) {
            random^=random<<13;random^=random>>17;random^=random<<5;
            bits=(update%7)?random:0;memcpy(&resource,&bits,8);
            unsigned kind=random%4,index=(random>>8)%(kind<2?31:kind==2?128:16);
            switch(kind) {
            case 0:[owner setAddress:bits atIndex:index];[reference setAddress:bits atIndex:index];break;
            case 1:[owner setAddress:bits attributeStride:random%256 atIndex:index];[reference setAddress:bits attributeStride:random%256 atIndex:index];break;
            case 2:[owner setTexture:resource atIndex:index];[reference setTexture:resource atIndex:index];break;
            default:[owner setSamplerState:resource atIndex:index];[reference setSamplerState:resource atIndex:index];break;
            }
        }
        equal(native,reference);[owner clearForReuse];fullClear(reference);equal(native,reference);
    }
    before=native->calls;
    unsigned rejected=0;
    @try{[owner setAddress:1 atIndex:31];}@catch(NSException *e){(void)e;rejected++;}
    @try{[owner setAddress:1 attributeStride:1 atIndex:NSUIntegerMax];}@catch(NSException *e){(void)e;rejected++;}
    @try{[owner setTexture:resource atIndex:128];}@catch(NSException *e){(void)e;rejected++;}
    @try{[owner setSamplerState:resource atIndex:16];}@catch(NSException *e){(void)e;rejected++;}
    assert(rejected==4&&native->calls==before);
    assert(![[HvMetal4Arguments alloc]initWithTable:nil]);
    puts("PASS Metal4 argument reuse: native table identity, full first initialization, sparse reset 175->3 calls, 50,000 updates vs full-clear reference, high slots, nils and invalid indices");
    return 0;
}}
