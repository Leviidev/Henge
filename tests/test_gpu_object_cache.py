"""Production object-resolution method with controlled guest metadata and resource factories.
Tests cache lifetime/identity; not a replacement for real guest Metal workload testing.
"""
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[1];s=(r/'devices/pvg_metal.m').read_text()
a=s.index('- (HvObject *)object:(uint32_t)ref task:(uint32_t)task {');i=s.index('{',a)+1;depth=1
while depth:
 if s[i]=='{':depth+=1
 if s[i]=='}':depth-=1
 i+=1
pre=r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include "gpu_epoch_cache.h"
enum {OBJ_BUFFER=1,OBJ_TEXTURE=2,OBJ_FUNCTION=6,OBJ_SERIALIZED=7,OBJ_LINEAR_TEXTURE=8,OBJ_MAPPED_TEXTURE=11};
typedef void HvPvgLite;
static uint32_t entries[2][256][3];static unsigned guest_reads;
static uint64_t hv_pvg_lite_task_objects(HvPvgLite *l,uint32_t t){(void)l;(void)t;return 1;}
static int hv_pvg_lite_task_read(HvPvgLite *l,uint32_t t,uint64_t at,void *out,uint32_t n){(void)l;assert(t<2&&n==12);memcpy(out,entries[t][(at-1)/12],n);guest_reads++;return 0;}
@interface HvObject:NSObject { @public id object;uint32_t entry[3];HvObject *follows;void *mapped;uint32_t generation,follows_generation; }
@end
@implementation HvObject @end
@interface HvReplay:NSObject { @public
 BOOL batch_cache;uint64_t current_epoch,object_hits,object_reads;HvPvgLite *lite;
 struct HvGpuEpochKey object_keys[HV_GPU_EPOCH_SLOTS];HvObject *object_values[HV_GPU_EPOCH_SLOTS];
 NSMutableDictionary *tasks;
}
-(HvObject *)object:(uint32_t)ref task:(uint32_t)task;
-(void)makeBuffer:(HvObject *)o at:(uint64_t)a task:(uint32_t)t;
-(void)makeTexture:(HvObject *)o at:(uint64_t)a size:(uint32_t)n task:(uint32_t)t;
-(id)makeFunction:(uint64_t)a task:(uint32_t)t;
-(id)makeSerialized:(uint64_t)a length:(uint32_t)n task:(uint32_t)t;
-(void)makeLinearTexture:(HvObject *)o at:(uint64_t)a size:(uint32_t)n task:(uint32_t)t;
-(void)makeHeap:(HvObject *)o at:(uint64_t)a task:(uint32_t)t;
-(void)makeHeapBuffer:(HvObject *)o at:(uint64_t)a task:(uint32_t)t;
-(void)makeMappedTexture:(HvObject *)o at:(uint64_t)a task:(uint32_t)t;
-(void)complain:(NSString *)s;
@end
static void refresh_pages(HvReplay *r,uint32_t t,HvObject *o){(void)r;(void)t;(void)o;}
@implementation HvReplay
-(void)makeBuffer:(HvObject *)o at:(uint64_t)a task:(uint32_t)t{(void)a;(void)t;o->object=[NSObject new];}
-(void)makeTexture:(HvObject *)o at:(uint64_t)a size:(uint32_t)n task:(uint32_t)t{(void)a;(void)n;(void)t;o->object=[NSObject new];}
-(id)makeFunction:(uint64_t)a task:(uint32_t)t{(void)a;(void)t;return[NSObject new];}
-(id)makeSerialized:(uint64_t)a length:(uint32_t)n task:(uint32_t)t{(void)a;(void)n;(void)t;return[NSObject new];}
-(void)makeLinearTexture:(HvObject *)o at:(uint64_t)a size:(uint32_t)n task:(uint32_t)t{[self makeTexture:o at:a size:n task:t];}
-(void)makeHeap:(HvObject *)o at:(uint64_t)a task:(uint32_t)t{[self makeBuffer:o at:a task:t];}
-(void)makeHeapBuffer:(HvObject *)o at:(uint64_t)a task:(uint32_t)t{[self makeBuffer:o at:a task:t];}
-(void)makeMappedTexture:(HvObject *)o at:(uint64_t)a task:(uint32_t)t{[self makeBuffer:o at:a task:t];}
-(void)complain:(NSString *)msg{(void)msg;assert(0);}
'''
post=r'''
@end
int main(void){@autoreleasepool{
 HvReplay *r=[HvReplay new];r->tasks=[NSMutableDictionary new];r->batch_cache=YES;r->current_epoch=1;
 entries[0][5][0]=6;HvObject *first=[r object:5 task:0];
 for(int i=0;i<10000;i++)assert([r object:5 task:0]==first);
 assert(guest_reads==1&&r->object_hits==10000);
 r->current_epoch=2;entries[0][5][1]=100;assert([r object:5 task:0]!=first&&guest_reads==2);
 entries[1][5][0]=6;assert([r object:5 task:1]!=first&&guest_reads==3);
 entries[0][69][0]=7;[r object:69 task:0];[r object:5 task:0];assert(guest_reads==5);
 entries[0][8][0]=2;HvObject *texture=[r object:8 task:0];entries[0][8][1]=200;
 assert([r object:8 task:0]!=texture);assert(guest_reads==7);
 r->current_epoch=0;[r object:5 task:0];[r object:5 task:0];assert(guest_reads==9);
 r->current_epoch=3;r->batch_cache=NO;[r object:5 task:0];[r object:5 task:0];assert(guest_reads==11);
 puts("production GPU object resolution: 10001 immutable accesses -> 1 guest metadata read; task/command/collision invalidation, mutable textures and disabled fallback passed");
}}
'''
b=r/'build';b.mkdir(exist_ok=True);p=b/'test_gpu_object_cache.m';p.write_text(pre+s[a:i]+post)
subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-Wall','-Wextra','-Werror','-I'+str(r/'devices'),str(p),'-framework','Foundation','-o',str(b/'test_gpu_object_cache')],check=True)
subprocess.run([str(b/'test_gpu_object_cache')],check=True,timeout=15)
