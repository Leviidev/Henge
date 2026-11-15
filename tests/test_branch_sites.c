/* Production generated branch-site path, including code/ASID/cache changes. */
#include "machine.h"
#include "dispatch.h"
#include "mmu.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HvMachine m;
static HvCpu cpu, other;
static uint32_t *code, *a, *b;
static void run(uint32_t *target, unsigned n, uint64_t expected) {
    cpu.pc=(uintptr_t)code; cpu.x[20]=(uintptr_t)target; cpu.x[24]=n;
    cpu.x[0]=0; cpu.x[1]=0x1122334455667788ull;
    for(unsigned i=0;i<32;i++)cpu.v[i]=((__uint128_t)(0x0123456789abcdefull+i)<<64)|(0xfedcba9876543210ull-i);
    assert(hv_run(&cpu)==HV_EXIT_HALT);
    for(unsigned i=0;i<32;i++)assert(cpu.v[i]==(((__uint128_t)(0x0123456789abcdefull+i)<<64)|(0xfedcba9876543210ull-i)));
    assert(cpu.x[0]==expected && !cpu.x[24]);
    assert(cpu.x[1]==0x1122334455667788ull && (cpu.nzcv&0x40000000u));
}
static void reset_user(void) {
    hv_cpu_reset(&cpu,&m); cpu.el=0; cpu.spsel=0; cpu.cpacr_el1=3u<<20;
}
int main(void) {
    assert(!hv_machine_init(&m,4<<20));
    enum {RAM=2<<20};
    code=aligned_alloc(16384,RAM); assert(code); memset(code,0,RAM);
    a=code+4096;
    reset_user();
    /* Force a real two-way collision, not merely two independent buckets. */
    uint32_t index=hv_ijc_index((uintptr_t)a^cpu.ijc_salt[0]);
    for(unsigned offset=32768;offset+8<RAM;offset+=4)
        if(hv_ijc_index(((uintptr_t)code+offset)^cpu.ijc_salt[0])==index){b=(uint32_t *)((char *)code+offset);break;}
    assert(b);
    code[0]=0xd63f0280; /* BLR X20 */
    code[1]=0xf1000718; code[2]=0x54ffffc1; /* SUBS X24,#1; B.NE code */
    a[0]=0x91000400; a[1]=0xd65f03c0; /* ADD X0,#1; RET */
    b[0]=0x91000c00; b[1]=0xd65f03c0; /* ADD X0,#3; RET */
    assert(!hv_machine_add_ram(&m,(uintptr_t)code,RAM,code,0));
    m.stop_pc=(uintptr_t)(code+3); reset_user();
    /* Real cold-path observations, then normal source retranslation. */
    for(int i=0;i<4;i++){hv_ijc_reset(&cpu,0);run(a,32,32);}
    uint64_t before=m.branch_hint_emissions;
    hv_flush_blocks(&m); run(a,128,128);
    if(m.branch_site_hints) assert(m.branch_hint_emissions>before);
    else assert(!m.branch_hint_emissions);
    uint64_t observations=cpu.pc_state->branch_observations;
    /* A warmed hit must not call the C observer or add counters. */
    run(a,10000,10000); assert(cpu.pc_state->branch_observations==observations);
    /* A formerly monomorphic site must follow a new target and switch back. */
    run(b,128,384);run(a,128,128);
    hv_ijc_drop_va(&cpu,(uintptr_t)a,-1);run(a,128,128);
    cpu.ttbr0_el1=7ull<<48;hv_ijc_switch(&cpu);run(a,128,128);
    /* The same slot address survives invalidation; its old target must not. */
    a[0]=0x91001400;hv_invalidate_code(&m,(uintptr_t)a);run(a,128,640);
    hv_flush_blocks(&m);run(a,128,640);
    hv_evict_blocks(&m);run(a,128,640);
    hv_cpu_reset_index(&other,&m,1);
    assert(other.ijc_site_hints!=cpu.ijc_site_hints);
    for(unsigned i=0;i<HV_IJC_TABLES;i++)for(unsigned j=0;j<32;j++)assert(!other.pc_state->ijc_sites[i][j]);
    reset_user();run(a,128,640);
    printf("PASS branch sites: enabled=%d emissions=%llu; real activation, warm hit, new target, TLBI, ASID, SMC, eviction, reset, CPU isolation\n",m.branch_site_hints,(unsigned long long)m.branch_hint_emissions);
    hv_machine_free(&m);free(code);
}
