#include "machine.h"
#include "dispatch.h"
#include "sysreg.h"
#include "translate.h"
#include <assert.h>
#include <stdio.h>

#define SR(a,b,c,d,e) ((a)<<14|(b)<<11|(c)<<7|(d)<<3|(e))
static HvMachine m;
static HvCpu cpu, reference;
static uint32_t code[4096] __attribute__((aligned(16384)));

static void prepare(void) {
    hv_flush_blocks(&m);
    hv_cpu_reset(&cpu,&m);
    cpu.pc=(uintptr_t)code;
    cpu.cpacr_el1=3u<<20;
    for(int i=0;i<31;i++)cpu.x[i]=0x123400000000ull+(unsigned)i;
}
int main(void) {
    assert(!hv_machine_init(&m,4<<20));
    assert(!hv_machine_add_ram(&m,(uintptr_t)code,sizeof code,code,1));
    m.stats_interval=3600;
    const unsigned regs[]={SR(3,0,2,0,2),SR(3,0,7,4,0),SR(3,0,4,2,3),
                           SR(3,0,2,0,0),SR(3,0,2,0,1),SR(3,0,4,2,4)};
    unsigned checks=0;
    for(unsigned r=0;r<sizeof regs/sizeof regs[0];r++)for(unsigned rt=0;rt<32;rt++)for(unsigned pan=0;pan<4;pan++) {
        prepare();
        code[0]=0xd5200000u|(regs[r]<<5)|rt;
        cpu.pstate_extra=(pan&1?HV_PSTATE_PAN:0) | (pan&2?1u<<23:0);
        /* High bits exercise full 64-bit loads, not a truncating W load. */
        cpu.tcr_el1=0xabcduLL<<32;cpu.par_el1=0x123456789abcdef0ull;
        cpu.ttbr0_el1=0xa123456789ab4000ull;cpu.ttbr1_el1=0xb9876543210c8000ull;
        reference=cpu;
        assert(!hv_sysreg_mrs(&reference,code[0],cpu.pc));
        m.stop_pc=(uintptr_t)(code+1);
        uint64_t before=m.stats.helper[HV_OP_MRS];
        assert(hv_run(&cpu)==HV_EXIT_HALT);
        for(unsigned i=0;i<31;i++)assert(cpu.x[i]==reference.x[i]);
        assert(m.stats.helper[HV_OP_MRS]==before); /* real generated path, no helper */
        checks++;
    }
    /* EL0 must still enter the original undefined-instruction exception path. */
    for(unsigned r=0;r<sizeof regs/sizeof regs[0];r++) {
        prepare();code[0]=0xd5200000u|(regs[r]<<5);
        cpu.el=0;cpu.spsel=0;cpu.vbar_el1=0;
        uint64_t old=cpu.x[0], before=m.stats.helper[HV_OP_MRS];
        m.stop_pc=0x400;
        assert(hv_run(&cpu)==HV_EXIT_HALT);
        assert(cpu.el==1 && cpu.elr_el1==(uintptr_t)code && cpu.x[0]==old);
        assert(m.stats.helper[HV_OP_MRS]==before+1);
    }
    /* Writes keep the original helpers, including PAN block-key changes. */
    for(unsigned r=0;r<sizeof regs/sizeof regs[0];r++)for(unsigned pan=0;pan<2;pan++) {
        prepare();
        cpu.x[0]=r==2?(pan?HV_PSTATE_PAN:0):r==5?(pan?1u<<23:0):0xabcdef0123450000ull;
        cpu.pstate_extra=pan?0:HV_PSTATE_PAN;
        code[0]=0xd5000000u|(regs[r]<<5);
        code[1]=0xd5200000u|(regs[r]<<5)|1;
        reference=cpu;
        assert(!hv_sysreg_msr(&reference,code[0],cpu.pc));
        assert(!hv_sysreg_mrs(&reference,code[1],cpu.pc+4));
        m.stop_pc=(uintptr_t)(code+2);
        uint64_t before=m.stats.helper[HV_OP_MSR];
        assert(hv_run(&cpu)==HV_EXIT_HALT);
        assert(cpu.x[1]==reference.x[1]);
        assert(cpu.tcr_el1==reference.tcr_el1 && cpu.par_el1==reference.par_el1);
        assert(cpu.ttbr0_el1==reference.ttbr0_el1 && cpu.ttbr1_el1==reference.ttbr1_el1);
        assert(cpu.pstate_extra==reference.pstate_extra);
        assert(m.stats.helper[HV_OP_MSR]==before+1);
    }
    /* Monterey requires AArch64-only SCTLR read-back after writes. */
    const uint64_t sctlr_values[] = {0, ~0ull, 0x10007414519dull};
    for (unsigned i = 0; i < 3; i++) {
        prepare();
        cpu.x[0] = sctlr_values[i];
        // Keep M clear so the test code remains identity-mapped.
        cpu.x[0] &= ~1ull;
        code[0] = 0xd5000000u | (SR(3,0,1,0,0) << 5);
        code[1] = 0xd5200000u | (SR(3,0,1,0,0) << 5) | 1;
        m.stop_pc = (uintptr_t)(code + 2);
        assert(hv_run(&cpu) == HV_EXIT_HALT);
        assert(cpu.x[1] == ((cpu.x[0] | 1u<<7 | 1u<<8) & ~(uint64_t)(1u<<5)));
    }
    /* Virtual reads use the same reset origin as the helper/timer model;
       physical reads remain host absolute time. Include all stolen regs/XZR. */
    const unsigned counters[]={SR(3,3,14,0,1),SR(3,3,14,0,5),SR(3,3,14,0,2),SR(3,3,14,0,6)};
    m.cntvoff=hv_counter();
    unsigned counter_checks=0;
    for(unsigned r=0;r<4;r++)for(unsigned rt=0;rt<32;rt++)for(unsigned el=0;el<2;el++) {
        prepare();
        assert(cpu.cntvoff==m.cntvoff);
        cpu.el=el;cpu.spsel=el;cpu.cntkctl_el1=3;cpu.el0_cnt=3;
        code[0]=0xd5200000u|(counters[r]<<5)|rt;
        uint64_t lo=hv_counter()-(r>=2?cpu.cntvoff:0);
        m.stop_pc=(uintptr_t)(code+1);
        assert(hv_run(&cpu)==HV_EXIT_HALT);
        uint64_t hi=hv_counter()-(r>=2?cpu.cntvoff:0);
        if(rt<31 && !(cpu.x[rt]>=lo && cpu.x[rt]<=hi)) {
            fprintf(stderr,"counter mismatch kind=%u rt=%u el=%u got=%llu lo=%llu hi=%llu origin=%llu commpage_type=%u\n",r,rt,el,(unsigned long long)cpu.x[rt],(unsigned long long)lo,(unsigned long long)hi,(unsigned long long)cpu.cntvoff,*(volatile unsigned char *)(uintptr_t)0xfffffc090ull);
            assert(0);
        }
        counter_checks++;
    }
    for(unsigned r=0;r<4;r++)for(unsigned rt=0;rt<32;rt+=31) {
        prepare();cpu.el=0;cpu.spsel=0;cpu.vbar_el1=0;
        code[0]=0xd5200000u|(counters[r]<<5)|rt;
        m.stop_pc=0x400;
        assert(hv_run(&cpu)==HV_EXIT_HALT);
        assert(cpu.el==1 && cpu.elr_el1==(uintptr_t)code);
    }
    printf("PASS counter origin: %u physical/virtual EL0/EL1 destination cases; permission traps incl. XZR; shared CPU reset origin\n",counter_checks);
    hv_machine_free(&m);
    printf("PASS inline EL1 MRS: %u register/PAN cases match helper, zero helper exits, all destinations incl. stolen/XZR; EL0 traps retained; fastmem offsets unchanged\n",checks);
}
