#include "machine.h"
#include "dispatch.h"
#include "translate.h"
#include <assert.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const char mem_programs_begin[],mem_programs_finish[],bench_stack_groups[],bench_stack_groups_end[];
static HvMachine machine;
static HvCpu cpu;
static uint64_t initial_sp;
static void run(unsigned iterations) {
    cpu.pc=(uintptr_t)bench_stack_groups;cpu.sp=initial_sp;cpu.x[2]=iterations;
    cpu.x[19]=19;cpu.x[20]=20;cpu.x[21]=21;cpu.x[22]=22;cpu.x[29]=29;cpu.x[30]=30;
    assert(hv_run(&cpu)==HV_EXIT_HALT);
    assert(!cpu.x[2]&&cpu.sp==initial_sp&&cpu.x[19]==19&&cpu.x[20]==20&&cpu.x[21]==21&&cpu.x[22]==22&&cpu.x[29]==29&&cpu.x[30]==30);
}
int main(int argc,const char **argv) {
    unsigned round=argc>1?(unsigned)atoi(argv[1]):0;
    assert(!hv_machine_init(&machine,4<<20));machine.chain=1;machine.stats_interval=1;
    hv_knob[HV_K_GROUPS]=2;
    uint8_t *stack=aligned_alloc(16384,65536);assert(stack);memset(stack,0x5a,65536);
    initial_sp=(uintptr_t)stack+32768;
    assert(!hv_machine_add_ram(&machine,(uintptr_t)mem_programs_begin,mem_programs_finish-mem_programs_begin,(void *)mem_programs_begin,1));
    assert(!hv_machine_add_ram(&machine,(uintptr_t)stack,65536,stack,0));
    machine.stop_pc=(uintptr_t)bench_stack_groups_end;
    hv_cpu_reset(&cpu,&machine);cpu.cpacr_el1=3u<<20;
    run(2000);
    mach_timebase_info_data_t tb;assert(!mach_timebase_info(&tb));
    uint64_t start=mach_absolute_time();run(500000);
    double ns=(double)(mach_absolute_time()-start)*tb.numer/tb.denom;
    printf("stack-group-bench: round=%u writeback=%d ns_per_frame=%.3f inline_words=%llu result=correct\n",round,hv_translate_writeback_groups(),ns/500000,(unsigned long long)machine.stats.words_inline);
    hv_machine_free(&machine);free(stack);return 0;
}
