#include "machine.h"
#include "dispatch.h"
#include <assert.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static HvMachine m;static HvCpu cpu;
static uint64_t read_device(void *opaque,uint64_t offset,unsigned size){(void)opaque;(void)offset;(void)size;return 1;}
static uint32_t branch(uint32_t op,const uint32_t *from,const uint32_t *to){return op|((uint32_t)(to-from)&0x3ffffff);}
int main(void){
 enum {H=128,C=4096,P=16384};
 int memory=getenv("HV_RETENTION_MMIO")!=NULL;
 assert(!hv_machine_init(&m,256<<10));unsigned char *ram=aligned_alloc(P,(H+C+1)*P);assert(ram);memset(ram,0,(H+C+1)*P);
 for(int i=0;i<H;i++){uint32_t *p=(uint32_t *)(ram+i*P);unsigned n=0;p[n++]=0x91000421;if(memory)p[n++]=0xf9400123;p[n]=i+1==H?0xd65f03c0:branch(0x14000000,p+n,(uint32_t *)(ram+(i+1)*P));}
 uint32_t *hot=(uint32_t *)ram,*cold=(uint32_t *)(ram+H*P),*tail=(uint32_t *)(ram+(H+C)*P);
 for(int i=0;i<C;i++){uint32_t *p=(uint32_t *)(ram+(H+i)*P);p[0]=0x91000400;p[1]=branch(0x94000000,p+1,hot);p[2]=branch(0x14000000,p+2,(uint32_t *)(ram+(H+i+1)*P));}
 tail[0]=0xf1000442;tail[1]=branch(0x14000000,tail+1,cold); /* patch conditional via C stop after one scan */
 assert(!hv_machine_add_ram(&m,(uintptr_t)ram,(H+C+1)*P,ram,0));m.stop_pc=(uintptr_t)tail;
 if(memory)assert(!hv_machine_add_mmio(&m,0x20000000,4096,NULL,read_device,NULL,"retention-bench"));
 hv_knob[HV_K_JITSEGS]=8;hv_flush_blocks(&m);hv_cpu_reset(&cpu,&m);cpu.el=0;cpu.spsel=0;cpu.pc=(uintptr_t)cold;cpu.cpacr_el1=3u<<20;
 cpu.x[9]=0x20000000;
 mach_timebase_info_data_t tb;assert(!mach_timebase_info(&tb));uint64_t start=mach_absolute_time();assert(hv_run(&cpu)==HV_EXIT_HALT);double ns=(double)(mach_absolute_time()-start)*tb.numer/tb.denom;
 assert(cpu.x[0]==C&&cpu.x[1]==(uint64_t)C*H);
 printf("retention-bench: memory=%d reference=%d ns=%.0f translations=%llu evictions=%llu nonfifo=%llu repaired=%llu result=correct\n",memory,!m.jit_retention,ns,(unsigned long long)m.stats.translations,(unsigned long long)m.stats.evictions,(unsigned long long)m.jit.retention_nonfifo,(unsigned long long)m.stats.evict_unchained);
 hv_machine_free(&m);free(ram);
}
