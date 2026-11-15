#include "machine.h"
#include "dispatch.h"
#include <assert.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern const char mem_programs_begin[],mem_programs_finish[],bench_interleaved_groups[],bench_interleaved_groups_end[];
static HvMachine m;static HvCpu cpu;
static void run(unsigned iterations,void *data){cpu.pc=(uintptr_t)bench_interleaved_groups;cpu.x[0]=(uintptr_t)data;cpu.x[24]=iterations;cpu.x[10]=0;assert(hv_run(&cpu)==HV_EXIT_HALT);assert(!cpu.x[24]&&cpu.x[10]==iterations*2ull);}
int main(void){
 assert(!hv_machine_init(&m,8<<20));m.stats_interval=1;
 void *data=aligned_alloc(16384,65536);assert(data);memset(data,0,65536);
 for(int i=0;i<65536;i+=8)*(uint64_t *)((char *)data+i)=1;
 assert(!hv_machine_add_ram(&m,(uintptr_t)data,65536,data,0));
 assert(!hv_machine_add_ram(&m,(uintptr_t)mem_programs_begin,mem_programs_finish-mem_programs_begin,(void *)mem_programs_begin,1));
 m.stop_pc=(uintptr_t)bench_interleaved_groups_end;
 mach_timebase_info_data_t tb;assert(!mach_timebase_info(&tb));
 for(int round=0;round<5;round++)for(int k=0;k<2;k++){
  int mode=(k^(round&1))?2:0;hv_knob[HV_K_GROUPS]=mode;hv_flush_blocks(&m);hv_cpu_reset(&cpu,&m);cpu.cpacr_el1=3u<<20;
  run(1000,data);uint64_t start=mach_absolute_time();run(300000,data);double ns=(double)(mach_absolute_time()-start)*tb.numer/tb.denom;
  printf("interleaved-bench: round=%d groups=%d ns_per_six_loads=%.3f result=600000\n",round,mode,ns/300000);
 }
 hv_machine_free(&m);free(data);
}
