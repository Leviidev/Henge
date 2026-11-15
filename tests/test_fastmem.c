/* Portable tests of the real walker and invalidation paths. No JIT execution.
   Build with tests/fastmem_portable.sh on Linux; make test-fastmem on macOS. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fastmem.h"
#include "machine.h"
#include "mmu.h"

static HvMachine m;
static HvCpu cpu;
static unsigned char *ram;
static const uint64_t kernel = 0xfffffe0000010000ull;
#define PA 0x80000000ull
#define PG (1u << HV_TLB_PAGE_BITS)
#define RAM_BYTES (16 * PG)

/* The test never fetches instructions or takes guest exceptions. Portable
   linking supplies just the platform-dependent symbols retained by mmu.c. */
#ifdef HENGE_PORTABLE_TEST
int hv_knob[HV_K_COUNT];
void hv_ret_clear(HvCpu *c) { memset(c->ret_tab, 0, sizeof c->ret_tab); }
void hv_cpu_kick(HvCpu *c) { c->exit_req = 1; }
#endif

static uint64_t *table(unsigned page) { return (uint64_t *)(ram + page * PG); }
static unsigned leaf_page(uint64_t va) { return ((va ^ kernel) >> 25) ? 8 : 2; }
static uint64_t *leaf(uint64_t va) { return &table(leaf_page(va))[(va >> 14) & 2047]; }
static void map(uint64_t va, unsigned page, unsigned ap, unsigned attr) {
    table(0)[(va >> 36) & 63] = (PA + PG) | 3;
    table(1)[(va >> 25) & 2047] = (PA + leaf_page(va) * PG) | 3;
    *leaf(va) = (PA + page * PG) | 3 | 1u << 10 | (uint64_t)ap << 6 | (uint64_t)attr << 2;
    hv_tlb_flush_va_page(&cpu, va, -1); /* page-table edits require invalidation */
}
static void read_ok(uint64_t va, void *want, int pan) {
    uint64_t pa;
    cpu.pstate_extra = pan ? HV_PSTATE_PAN : 0;
    assert(hv_mmu_access(&cpu, va, HV_ACC_READ, 1, &pa) == 0);
    assert(hv_fastmem_read_ptr(&cpu, va, 8, pan ? 2 : 1) == want);
}

int main(void) {
    ram = aligned_alloc(PG, RAM_BYTES);
    assert(ram);
    memset(ram, 0, RAM_BYTES);
    cpu.m = &m;
    cpu.pc_state = &m.percpu[0];
    cpu.next_cid = 1;
    m.fastmem_diagnostics = 1;
    m.nram = 1;
    m.ram[0] = (HvRam){.pa = PA, .size = RAM_BYTES, .host = ram, .npages = 16};
    m.ram[0].code_pages = calloc(16, 1);
    m.ram[0].whint = calloc(16 * HV_MAX_CPUS, sizeof(uint64_t));
    assert(m.ram[0].code_pages && m.ram[0].whint);
    assert(hv_fastmem_attach(&cpu, &cpu.pc_state->fastmem, 0) == 0);
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    assert(hv_fastmem_attach(&cpu, &cpu.pc_state->fastmem, 1) == 0);
    /* Kernel map regions observed in the Duo logs must work immediately;
       no boot-time election can exclude a later region. */
    const uint64_t windows[] = {0xfffffcf000010000ull, 0xfffffc0400020000ull,
                                 0xfffffe0000030000ull, 0xfffffe1000040000ull};
    for (unsigned i = 0; i < 4; i++) for (int pan = 1; pan <= 2; pan++)
        hv_fastmem_fill(&cpu, windows[i], pan, (uintptr_t)(ram + (i + 3) * PG) - windows[i]);
    for (unsigned i = 0; i < 4; i++) for (int pan = 1; pan <= 2; pan++)
        assert(hv_fastmem_read_ptr(&cpu, windows[i], 8, pan) == ram + (i + 3) * PG);
    assert(!hv_fastmem_read_ptr(&cpu, 0, 8, 1));
    uint64_t collision = windows[0] + HV_FASTMEM_SIZE;
    hv_fastmem_fill(&cpu, collision, 1, (uintptr_t)(ram + 7 * PG) - collision);
    assert(!hv_fastmem_read_ptr(&cpu, windows[0], 8, 1));
    assert(hv_fastmem_read_ptr(&cpu, collision, 8, 1) == ram + 7 * PG);
    assert(hv_fastmem_read_ptr(&cpu, windows[0], 8, 2) == ram + 3 * PG);
    hv_fastmem_drop(&cpu, windows[0], PG); // drop must not alias another window
    assert(hv_fastmem_read_ptr(&cpu, collision, 8, 1) == ram + 7 * PG);
    assert(!hv_fastmem_read_ptr(&cpu, windows[0], 8, 2));
    hv_fastmem_drop(&cpu, collision, PG);
    assert(!hv_fastmem_read_ptr(&cpu, collision, 8, 1));
    // A huge range clears matching windows without overflowing its end.
    hv_fastmem_drop(&cpu, windows[1] - 1, UINT64_MAX);
    for (unsigned i = 1; i < 4; i++) for (int pan = 1; pan <= 2; pan++)
        assert(!hv_fastmem_read_ptr(&cpu, windows[i], 8, pan));
    HvFastmemSnapshot snap;
    assert(hv_fastmem_snapshot(&cpu, &snap) && snap.reanchors == 0);
    assert(!hv_fastmem_attach(&cpu, &cpu.pc_state->fastmem, 1));
    cpu.sctlr_el1 = 1;
    cpu.ttbr1_el1 = PA;
    cpu.mair_el1 = 0xff; /* AttrIndx 0 normal, 1 device */
    cpu.tcr_el1 = 22ull << 16 | 1ull << 30; /* TTBR1 42-bit VA, 16K pages */
    hv_tlb_tmajor = 1;
    map(kernel, 3, 2, 0); /* read-only pages are allowed for reads */
    read_ok(kernel + 40, ram + 3 * PG + 40, 0);
    *(uint64_t *)(ram + 3 * PG + 40) = 0x12345678;
    assert(*(uint64_t *)hv_fastmem_read_ptr(&cpu, kernel + 40, 8, 1) == 0x12345678);
    assert(!hv_fastmem_read_ptr(&cpu, kernel + PG - 8, 8, 1));
    assert(hv_fastmem_read_ptr(&cpu, kernel + PG - 16, 8, 1));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 0));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 16, 1));
    assert(!hv_fastmem_read_ptr(&cpu, kernel + HV_FASTMEM_SIZE, 8, 1));
    assert(!hv_fastmem_read_ptr(&cpu, kernel - HV_FASTMEM_SIZE, 8, 1));
    assert(!hv_fastmem_read_ptr(&cpu, 0xabfffe0000010000ull, 8, 1));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 2)); /* independent PAN table */
    read_ok(kernel, ram + 3 * PG, 1);
    /* Pages 256 MB apart collide in Henge's existing software TLB. Both
       translations survive independently in the experimental read LUT. */
    uint64_t other = kernel + (256ull << 20);
    map(other, 5, 2, 0);
    read_ok(other, ram + 5 * PG, 0);
    assert(hv_fastmem_read_ptr(&cpu, kernel, 8, 1) == ram + 3 * PG);

    /* One-page TLBI must drop both permission views, including tagged VAs. */
    hv_tlb_flush_va_asid(&cpu, kernel & 0x00ffffffffffffffull, -1);
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 2));
    assert(hv_fastmem_read_ptr(&cpu, other, 8, 1) == ram + 5 * PG);
    read_ok(kernel, ram + 3 * PG, 0);
    read_ok(kernel, ram + 3 * PG, 1);
    hv_tlb_flush_va_page(&cpu, kernel & 0x00ffffffffffffffull, -1);
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 2));
    assert(hv_fastmem_read_ptr(&cpu, other, 8, 1) == ram + 5 * PG);
    map(kernel, 4, 2, 0);
    read_ok(kernel, ram + 4 * PG, 0); /* remapped PA */
    hv_tlb_flush_kernel_range(&cpu, kernel, 128ull << 20);
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));

    /* Device memory, unmapped physical memory, small pages and MMU-off reads
       must not enter the LUT even if ordinary TLB handling accepts them. */
    uint64_t pa;
    map(kernel, 4, 2, 1);
    assert(!hv_mmu_access(&cpu, kernel, HV_ACC_READ, 1, &pa));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    map(kernel, 17, 2, 0);
    assert(!hv_mmu_access(&cpu, kernel, HV_ACC_READ, 1, &pa));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    map(kernel, 4, 1, 0); /* EL0 accessible: PAN prohibits EL1 reads */
    cpu.pstate_extra = HV_PSTATE_PAN;
    assert(hv_mmu_access(&cpu, kernel, HV_ACC_READ, 1, &pa));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 2));
    read_ok(kernel, ram + 4 * PG, 0);
    assert(hv_tlbi_drop_remote_va(&cpu, kernel, -1) == -1); /* owner must ack */
    assert(hv_tlbi_drop_remote_range(&cpu, kernel, 2, -1) == -1);
    assert(hv_tlbi_drop_remote_range(&cpu, kernel & 0x00ffffffffffffffull, 2, -1) == -1);
    assert(hv_fastmem_read_ptr(&cpu, kernel, 8, 1)); /* no unsynchronized remote LUT edit */
    hv_tlb_flush(&cpu);
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    *leaf(kernel) = 0;
    assert(hv_mmu_access(&cpu, kernel, HV_ACC_READ, 1, &pa));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    cpu.sctlr_el1 = 0;
    assert(!hv_mmu_access(&cpu, kernel, HV_ACC_READ, 1, &pa));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    cpu.sctlr_el1 = 1;
    map(kernel, 3, 2, 0);
    read_ok(kernel, ram + 3 * PG, 0);
    /* User invalidations do not accidentally clear the kernel view. */
    hv_fastmem_drop(&cpu, 0x10000, UINT64_MAX);
    assert(hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    hv_fastmem_drop(&cpu, kernel - PG, UINT64_MAX); /* overflow-safe range */
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    hv_tlb_flush_va_page(&cpu, kernel, -1);
    read_ok(kernel, ram + 3 * PG, 0);
    assert(!hv_fastmem_attach(&cpu, &cpu.pc_state->fastmem, 1)); /* CPU reset */
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    /* EL0 accesses never populate the kernel cache. */
    map(kernel, 3, 3, 0);
    assert(!hv_mmu_access(&cpu, kernel, HV_ACC_READ, 0, &pa));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    /* A valid 4 KB guest mapping must stay on the existing helper path. */
    memset(ram, 0, 3 * PG);
    memset(table(8), 0, PG);
    cpu.tcr_el1 = 22ull << 16 | 2ull << 30;
    table(0)[(kernel >> 39) & 7] = (PA + PG) | 3;
    table(1)[(kernel >> 30) & 511] = (PA + 2 * PG) | 3;
    table(2)[(kernel >> 21) & 511] = (PA + 8 * PG) | 3;
    table(8)[(kernel >> 12) & 511] = (PA + 3 * PG) | 3 | 1u << 10;
    assert(!hv_mmu_access(&cpu, kernel, HV_ACC_READ, 1, &pa));
    assert(!hv_fastmem_read_ptr(&cpu, kernel, 8, 1));
    /* Repeated invalidation/refill cannot overflow the sparse clear list. */
    uint64_t addend = (uintptr_t)(ram + 3 * PG) - kernel;
    for (unsigned i = 0; i < 2 * HV_FASTMEM_PAGES + 1; i++) {
        hv_fastmem_fill(&cpu, kernel, 1, addend);
        hv_fastmem_drop(&cpu, kernel, PG);
    }
    hv_fastmem_fill(&cpu, kernel, 1, addend);
    assert(hv_fastmem_read_ptr(&cpu, kernel, 8, 1) == ram + 3 * PG);
    assert(hv_fastmem_snapshot(&cpu, &snap) && !snap.saturated);
    hv_fastmem_clear(&cpu);
    hv_fastmem_fill(&cpu, kernel, 1, addend);
    assert(hv_fastmem_read_ptr(&cpu, kernel, 8, 1) == ram + 3 * PG);
    assert(!hv_fastmem_attach(&cpu, &cpu.pc_state->fastmem, 0));
    assert(!cpu.fm_read[0] && !cpu.pc_state->fastmem);
    free(m.ram[0].code_pages);
    free(m.ram[0].whint);
    free(ram);
    puts("fastmem walker, permissions, invalidation and fallback tests passed");
}
