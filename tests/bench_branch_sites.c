/* Same guest execution with optional site hint, no hot-path instrumentation. */
#include "machine.h"
#include "dispatch.h"
#include "mmu.h"
#include <assert.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static HvMachine m;static HvCpu cpu;
static void run(uint32_t *code,uint32_t *a,uint32_t *b,unsigned n,int changing) {
    cpu.pc=(uintptr_t)code;cpu.x[20]=(uintptr_t)a;
    cpu.x[21]=(uintptr_t)a^(uintptr_t)b;cpu.x[24]=n;cpu.x[0]=0;
    assert(hv_run(&cpu)==HV_EXIT_HALT);
    assert(cpu.x[0]==(uint64_t)n*(changing?2:1));
}
int main(void) {
    assert(!hv_machine_init(&m,4<<20));
    uint32_t *code=aligned_alloc(16384,3*16384);assert(code);memset(code,0,3*16384);
    uint32_t *a=code+4096,*b=code+8192;
    a[0]=0x91000400;a[1]=0xd65f03c0;b[0]=0x91000c00;b[1]=0xd65f03c0;
    assert(!hv_machine_add_ram(&m,(uintptr_t)code,3*16384,code,0));
    mach_timebase_info_data_t tb;assert(!mach_timebase_info(&tb));
    for(int changing=0;changing<2;changing++)for(int round=0;round<5;round++)for(int k=0;k<3;k++) {
        int variant=round&1?2-k:k;
        m.branch_site_hints=variant==2;m.ijc_pair=variant==1;hv_flush_blocks(&m);hv_cpu_reset(&cpu,&m);
        cpu.el=0;cpu.spsel=0;cpu.cpacr_el1=3u<<20;
        code[0]=0xd63f0280;unsigned n=1;
        if(changing)code[n++]=0xca150294; /* EOR X20,X20,X21 */
        code[n++]=0xf1000718;code[n]=changing?0x54ffffa1:0x54ffffc1;n++;
        m.stop_pc=(uintptr_t)(code+n);
        /* Pre-existing stable history, including when target behaviour changes. */
        for(int i=0;i<3;i++)hv_ijc_site_observe(&cpu,(uintptr_t)code,(uintptr_t)a,0);
        uint64_t before=m.branch_hint_emissions;
        run(code,a,b,1000,changing);
        if(m.branch_site_hints)assert(m.branch_hint_emissions>before);
        uint64_t start=mach_absolute_time();run(code,a,b,20000000,changing);
        double ns=(double)(mach_absolute_time()-start)*tb.numer/tb.denom;
        printf("branch-site-bench: round=%d changing=%d variant=%d ns_per_call=%.3f result=correct\n",round,changing,variant,ns/20000000);
    }
    hv_machine_free(&m);free(code);
}
