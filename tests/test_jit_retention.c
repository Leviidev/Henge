#include "machine.h"
#include "dispatch.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
static HvMachine m;
int main(void){
 assert(!hv_machine_init(&m,1<<20));HvJitRegion *r=&m.jit;assert(r->nseg==8);
 uint64_t seen=3; /* segments0/1 represent repeatedly executing code */
 for(int i=0;i<32;i++){unsigned victim=hv_jit_evict_policy(r,seen,1);assert(victim>=2&&victim<8);}
 assert(r->retention_nonfifo>0);
 hv_jit_reset(r);
 for(unsigned i=0;i<16;i++){unsigned victim=hv_jit_evict_policy(r,0xff,1);assert(victim==(i%8));}
 hv_jit_ring(r,64);
 for(unsigned i=0;i<128;i++)assert(hv_jit_evict_policy(r,1ull<<63,1)!=63);
 hv_jit_ring(r,3);for(unsigned i=0;i<9;i++)assert(hv_jit_evict_policy(r,0,1)==i%3);
 hv_jit_ring(r,8);
 /* Birth order is arbitrary; diagnostic lookup must follow executable pages. */
 unsigned order[]={5,1,7,3};m.nblocks=4;
 for(unsigned i=0;i<4;i++){m.blocks[i].code=r->base+order[i]*r->seg_words+4;hv_block_index_add(&m,i);}
 for(unsigned i=0;i<4;i++)assert(hv_block_at(&m,m.blocks[i].code+2)==&m.blocks[i]);
 assert(!hv_block_at(&m,r->base+2*r->seg_words));
 free(m.jit_page_heads);m.jit_page_heads=NULL;
 for(unsigned i=0;i<4;i++)assert(hv_block_at(&m,m.blocks[i].code+2)==&m.blocks[i]);
 printf("PASS retention: protect executing segments; fair all-hot aging; non-FIFO host-PC lookup; HvBlock=%zu bytes\n",sizeof(HvBlock));
 assert(sizeof(HvBlock)==80);hv_machine_free(&m);
}
