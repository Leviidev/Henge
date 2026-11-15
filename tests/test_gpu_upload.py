"""Execute the production page-copy method with real Metal buffers/textures.
Only the controlled guest-memory lookup is supplied by the fixture.
"""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1];text=(root/'devices/pvg_metal.m').read_text()
a=text.index('- (BOOL)page:(HvObject *)o toGuest:');i=text.index('{',a)+1;depth=1
while depth:
 if text[i]=='{':depth+=1
 if text[i]=='}':depth-=1
 i+=1
method=text[a:i]
pre=r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <string.h>
#include "gpu_copy_bounds.h"
@interface HvObject:NSObject { @public
 uint64_t length,tex_base,tex_stride;uint32_t tex_mips,tex_slices;uint8_t tex_block_h;
 uint32_t *pages;uint8_t *tex_layout;id object;id<MTLBuffer> guest_copy,heap_whole;
} @end
@implementation HvObject @end
@interface HvReplay:NSObject
- (BOOL)page:(HvObject *)o toGuest:(BOOL)down task:(uint32_t)task blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb;
@end
static id<MTLBuffer> guest_copy(HvReplay *r,uint32_t task,HvObject *o){(void)r;(void)task;return o->guest_copy;}
static BOOL has_guest_pages(HvObject *o){for(uint64_t i=0;o->pages&&i<(o->length+16383)/16384;i++)if(o->pages[i])return YES;return NO;}
@implementation HvReplay
'''
post=r'''
@end
int main(void) {@autoreleasepool {
 id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
 id<MTLCommandQueue> queue=[device newCommandQueue];assert(queue);
 HvReplay *r=[HvReplay new];HvObject *o=[HvObject new];
 uint32_t pages[4]={1,1,1,1};uint8_t layout[72]={0};uint64_t row=256;uint32_t w=4,h=4,d=1;
 memcpy(layout+16,&row,8);memcpy(layout+24,&w,4);memcpy(layout+28,&h,4);memcpy(layout+32,&d,4);
 o->length=65536;o->pages=pages;o->tex_layout=layout;o->tex_mips=1;o->tex_slices=1;o->tex_block_h=1;
 o->guest_copy=[device newBufferWithLength:65536 options:MTLResourceStorageModeShared];assert(o->guest_copy);
 MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:YES];
 desc.storageMode=MTLStorageModePrivate;o->object=[device newTextureWithDescriptor:desc];assert(o->object);
 memset(o->guest_copy.contents,0x5f,65536);
 id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=nil;
 assert([r page:o toGuest:NO task:0 blit:&blit commandBuffer:cb]);[blit endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
 memset(o->guest_copy.contents,0,65536);cb=[queue commandBuffer];blit=nil;
 assert([r page:o toGuest:YES task:0 blit:&blit commandBuffer:cb]);[blit endEncoding];[cb commit];[cb waitUntilCompleted];assert(cb.status==MTLCommandBufferStatusCompleted);
 for(unsigned y=0;y<4;y++)for(unsigned x=0;x<16;x++)assert(((uint8_t *)o->guest_copy.contents)[y*256+x]==0x5f);
 pages[2]=0;cb=[queue commandBuffer];blit=nil;
 assert(![r page:o toGuest:NO task:0 blit:&blit commandBuffer:cb]&&!blit);pages[2]=1;
 o->tex_mips=2;memcpy(layout+36,layout,36);uint64_t bad=UINT64_MAX;memcpy(layout+36,&bad,8);
 cb=[queue commandBuffer];blit=nil;assert(![r page:o toGuest:NO task:0 blit:&blit commandBuffer:cb]&&!blit);
 o->tex_mips=0;assert(![r page:o toGuest:NO task:0 blit:&blit commandBuffer:cb]);
 puts("Metal upload: real pixel roundtrip; holes, incomplete mips and empty copies rejected before encoding");
}return 0;}
'''
b=root/'build';b.mkdir(exist_ok=True);c=b/'test_gpu_upload.m';c.write_text(pre+method+post)
subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-O1','-g','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-I'+str(root/'devices'),str(c),'-framework','Foundation','-framework','Metal','-o',str(b/'test_gpu_upload')],check=True)
subprocess.run([str(b/'test_gpu_upload')],check=True)
