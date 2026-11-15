#include "machine.h"
#include "dispatch.h"
#include "sysreg.h"
#include "mmu.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static HvMachine m;
static HvCpu cpu;
static uint32_t code[4096] __attribute__((aligned(16384))) = {0xd503207f, 0xd2800540}; /* WFI; MOV X0,#42 */
static unsigned activations;
static void became_active(void *opaque) { assert(opaque == &m); activations++; }
static uint64_t timer_tick(HvMachine *machine, HvCpu *c) {
    assert(machine == &m && c == &cpu);
    return hv_counter() + 24000; /* same 24 MHz deadline used by engine WFI */
}
int main(void) {
    alarm(15);
    assert(hv_machine_init(&m, 1 << 20) == 0);
    assert(hv_machine_add_ram(&m, (uintptr_t)code, sizeof code, code, 1) == 0);
    hv_cpu_reset(&cpu, &m);
    cpu.pc = (uintptr_t)code;
    cpu.cpacr_el1 = 3u << 20;
    m.stop_pc = (uintptr_t)(code + 2);
    m.tick = timer_tick;
    m.notify_cpu_active = became_active;
    m.activity_opaque = &m;
    assert(hv_run(&cpu) == HV_EXIT_HALT);
    assert(cpu.x[0] == 42);
    assert(m.stats.wfi == 1);
    assert(activations >= 2); /* initial entry and resumed guest timer wait */
    assert(!m.percpu[0].active);
    /* Basic WFE accounting must work with expensive peer probes disabled. */
    static uint32_t monitored[4096] __attribute__((aligned(16384)));
    static uint32_t wait_code[4096] __attribute__((aligned(16384))) = {0xd503205f, 0xd2800540};
    assert(!hv_machine_add_ram(&m, 0x90000000, sizeof monitored, monitored, 0));
    assert(!hv_machine_add_ram(&m, (uintptr_t)wait_code, sizeof wait_code, wait_code, 1));
    hv_cpu_reset(&cpu, &m); cpu.pc = (uintptr_t)wait_code; cpu.cpacr_el1 = 3u << 20;
    m.stop_pc = (uintptr_t)(wait_code + 2); m.stats_interval = 1; m.wait_stats = 0;
    uint64_t pa; assert(!hv_mmu_access(&cpu, 0x90000000, HV_ACC_READ, cpu.el, &pa));
    cpu.excl_addr = 0x90000000; cpu.excl_size = 4; cpu.excl_val[0] = 0;
    assert(hv_run(&cpu) == HV_EXIT_HALT && cpu.x[0] == 42);
    assert(m.percpu[0].wfe_ticks && m.percpu[0].wfe_timeouts);
    uint64_t exits = m.percpu[0].wfe_dispatches;
    hv_cpu_reset(&cpu, &m); cpu.pc = (uintptr_t)wait_code; cpu.cpacr_el1 = 3u << 20;
    cpu.excl_addr = ~0ull;
    assert(hv_run(&cpu) == HV_EXIT_HALT && cpu.x[0] == 42);
    assert(m.percpu[0].wfe_dispatches == exits + 1);
    m.stats_interval = 0;
    /* Periodic ticks may skip parked CPUs; explicit broadcasts must not. */
    static HvCpu parked;
    m.cpus[1] = &parked; m.ncpus = 2;
    cpu.exit_req = parked.exit_req = 0;
    m.percpu[0].active = 1; m.percpu[1].active = 0;
    assert(hv_machine_kick_active(&m) == 1);
    assert(cpu.exit_req == 1 && parked.exit_req == 0);
    cpu.exit_req = 0; m.percpu[0].active = 0;
    assert(hv_machine_kick_active(&m) == 0 && cpu.exit_req == 0 && parked.exit_req == 0);
    hv_machine_kick_all(&m);
    assert(cpu.exit_req == 1 && parked.exit_req == 1);
    cpu.exit_req = parked.exit_req = 0;
    m.percpu[0].active = m.percpu[1].active = 1;
    assert(hv_machine_kick_active(&m) == 2 && cpu.exit_req == 1 && parked.exit_req == 1);
    /* Deadline mode never delays CPU0 polling or explicit requests. */
    cpu.exit_req = parked.exit_req = 0;
    m.percpu[1].timer_deadline_valid = 0;
    assert(hv_machine_kick_due(&m, 100) == 2); // unknown timer state is conservative
    cpu.exit_req = parked.exit_req = 0;
    m.percpu[1].timer_deadline = 200; m.percpu[1].timer_deadline_valid = 1;
    assert(hv_machine_kick_due(&m, 100) == 1 && !parked.exit_req);
    cpu.exit_req = 0;
    assert(hv_machine_kick_due(&m, 200) == 2 && parked.exit_req);
    cpu.exit_req = parked.exit_req = 0; m.percpu[1].timer_deadline = 0;
    assert(hv_machine_kick_due(&m, 300) == 1 && !parked.exit_req);
    hv_cpu_kick(&parked); assert(parked.exit_req); // actual work bypasses filter
    m.percpu[0].active = m.percpu[1].active = 0;
    cpu.exit_req = parked.exit_req = 0;
    assert(hv_machine_kick_due(&m, 400) == 0);
    assert(atomic_load(&m.timer_kicks_cpu0) == 4);
    assert(atomic_load(&m.timer_kicks_due) == 1);
    assert(atomic_load(&m.timer_kicks_unknown) == 1);
    assert(atomic_load(&m.timer_kicks_deferred) == 2);
    hv_machine_free(&m);
    puts("native WFI integration: guest timer resumes code, activity callback runs at entry/resume, CPU parks on exit");
}
