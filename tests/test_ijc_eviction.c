#include "machine.h"
#include "mmu.h"
#include "dispatch.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
static HvMachine m;static HvCpu cpu;
static uintptr_t hit(uint64_t va,unsigned flags){uint64_t tag=va^cpu.ijc_salt[flags&1];uint64_t *entry=m.percpu[0].ijc+(size_t)flags*(HV_IJC_TABLE_BYTES/8)+2*hv_ijc_index(tag);return entry[0]==tag?entry[1]:entry[2]==tag?entry[3]:0;}
int main(void){
 assert(!hv_machine_init(&m,4<<20));hv_cpu_reset(&cpu,&m);assert(cpu.pc_state->ijc_segments);
 uint32_t *base=m.jit.base;size_t seg=m.jit.seg_words;assert(seg&&m.jit.nseg>=3);
 HvBlock a={.va=0x100000,.code=base+4},b={.code=base+seg+4},c={.va=0x300000,.code=base+2*seg+4};
 uint64_t index=hv_ijc_index(a.va^cpu.ijc_salt[0]);
 for(uint64_t i=1;i<(1u<<22);i++){uint64_t va=a.va+i*4;if(hv_ijc_index(va^cpu.ijc_salt[0])==index){b.va=va;break;}}
 assert(b.va);hv_ijc_fill(&cpu,&a);hv_ijc_fill(&cpu,&b);hv_ijc_fill(&cpu,&c);
 assert(hit(a.va,0)==(uintptr_t)a.code&&hit(b.va,0)==(uintptr_t)b.code);
 uint64_t salt=cpu.ijc_salt[0];assert(!hv_ijc_evict_range(&cpu,base,base+seg,NULL,0));
 assert(!hit(a.va,0)&&hit(b.va,0)==(uintptr_t)b.code&&hit(c.va,0)==(uintptr_t)c.code&&cpu.ijc_salt[0]==salt);
 /* A former segment's conservative bit must not drop a replacement target. */
 b.code=base+2*seg+8;hv_ijc_fill(&cpu,&b);
 assert(!hv_ijc_evict_range(&cpu,base+seg,base+2*seg,NULL,0));assert(hit(b.va,0)==(uintptr_t)b.code);
 uint64_t examined=m.ijc_evict_examined;
 assert(!hv_ijc_evict_range(&cpu,base+seg,base+2*seg,NULL,0));
 assert(m.ijc_evict_examined==examined); /* old overwritten bits were pruned */
 /* Stale blocks outside the selected segment are removed exactly too. */
 uint32_t *removed[]={b.code};assert(!hv_ijc_evict_range(&cpu,base,base+seg,removed,1));
 assert(!hit(b.va,0)&&hit(c.va,0)==(uintptr_t)c.code);
 hv_ijc_drop_asid(&cpu,0);assert(!hit(c.va,0));
 assert(m.ijc_evict_removed>=2&&m.ijc_evict_examined<100);
 hv_ijc_fill(&cpu,&c);
 free(cpu.pc_state->ijc_segments);cpu.pc_state->ijc_segments=NULL;cpu.pc_state->ijc_segment_count=0;
 hv_evict_blocks(&m);assert(!hit(c.va,0)); /* metadata allocation failure keeps full-reset fallback */
 printf("PASS selective IJC eviction: two ways, survivors, overwritten slots, stale outside segment, ASID invalidation; examined=%llu removed=%llu\n",(unsigned long long)m.ijc_evict_examined,(unsigned long long)m.ijc_evict_removed);
 hv_machine_free(&m);
}
