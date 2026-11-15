#include "harness.h"
#include "translate.h"

#include <stdlib.h>

DECLARE_PROGRAM(arith);
DECLARE_PROGRAM(loop);
DECLARE_PROGRAM(condbr);
DECLARE_PROGRAM(csel_ops);
DECLARE_PROGRAM(bl_sub);
DECLARE_PROGRAM(simd_fp);
DECLARE_PROGRAM(stolen);
DECLARE_PROGRAM(pcrel);
DECLARE_PROGRAM(long_block);
DECLARE_PROGRAM(pstate_bits);
DECLARE_PROGRAM(pac);
DECLARE_PROGRAM(hop);
extern const char jit_programs_begin[], jit_programs_finish[];

static const TestProgram programs[] = {
    TEST_PROGRAM(arith),   TEST_PROGRAM(loop),   TEST_PROGRAM(condbr),
    TEST_PROGRAM(csel_ops), TEST_PROGRAM(bl_sub), TEST_PROGRAM(simd_fp),
    TEST_PROGRAM(stolen),  TEST_PROGRAM(pcrel),  TEST_PROGRAM(long_block), TEST_PROGRAM(pstate_bits), TEST_PROGRAM(hop),
};

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    static HvMachine m;
    if (hv_machine_init(&m, 4 << 20) != 0) {
        printf("machine init failed\n");
        return 1;
    }
    /* The programs' own text is guest RAM at PA = host address, so ADR and
       pointer values agree with the native run. */
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)jit_programs_begin, jit_programs_finish - jit_programs_begin,
                       (void *)jit_programs_begin, 1);
    uint8_t *stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
    uint64_t sp = (uint64_t)(uintptr_t)stack + 32768;

    m.trace = getenv("HV_TRACE") != NULL;
    int failed = 0;
    // Reinitialising after an unset option must clear the old machine's knob.
    {
        static HvMachine probe;
        const char *old = getenv("HV_SUPERBLOCKS");
        char *saved = old ? strdup(old) : NULL;
        setenv("HV_SUPERBLOCKS", "1", 1);
        if (hv_machine_init(&probe, 4096) != 0) return 1;
        failed += hv_knob[HV_K_SUPERBLOCKS] != 1;hv_machine_free(&probe);
        unsetenv("HV_SUPERBLOCKS");
        if (hv_machine_init(&probe, 4096) != 0) return 1;
        failed += hv_knob[HV_K_SUPERBLOCKS] != 0;hv_machine_free(&probe);
        if (saved) {setenv("HV_SUPERBLOCKS",saved,1);free(saved);} else unsetenv("HV_SUPERBLOCKS");
        hv_knob[HV_K_SUPERBLOCKS] = getenv("HV_SUPERBLOCKS") ? atoi(getenv("HV_SUPERBLOCKS")) : 0;
    }

    size_t count = sizeof programs / sizeof programs[0];
    for (size_t i = 0; i < count; i++) {
        const TestProgram *p = &programs[i];
        /* Two seeds per program: one with flags clear, one with NZCV set going in. */
        for (int variant = 0; variant < 2; variant++) {
            static HvCpu init, native, jit;
            memset(&init, 0, sizeof init);
            seed_cpu(&init, i * 2 + variant + 1, sp);
            if (variant) init.nzcv = 0xa0000000;
            run_native(p, &init, &native, NULL);
            int bad = run_jit(&m, p, &init, &jit, NULL);
            if (!bad) bad = compare_cpus(p->name, &native, &jit);
            printf("%-12s seed %d: %s\n", p->name, variant, bad ? "FAIL" : "ok");
            failed += bad != 0;
        }
    }
    /* Exercise the production superblock emitter, not a copied policy:
       all three conditional branch classes, stolen register, bounds, and stop. */
    {
        int saved = hv_knob[HV_K_SUPERBLOCKS], chain = m.chain;
        m.chain = 0;
        const uint32_t branches[] = {0x54000040, 0xb4000040, 0xb5000046, 0x36000040, 0x37000046};
        for (unsigned k=0; k<sizeof branches/sizeof branches[0]; k++) {
            const uint32_t words[] = {branches[k], 0xd503201f, 0xd65f03c0};
            for (int enabled=0; enabled<=1; enabled++) {
                hv_knob[HV_K_SUPERBLOCKS] = enabled;
                HvBlock block = {.va=0x10000000, .pa=0x10000000};
                int bad = hv_translate_emit(&m, &block, words, 3) != 0 || block.ninsns != (enabled ? 3u : 1u);
                if (bad) printf("FAIL superblock branch class %u enabled %d count %u\n", k, enabled, block.ninsns);
                failed += bad;
            }
        }
        hv_knob[HV_K_SUPERBLOCKS] = 1;
        uint32_t branches64[64]; for(unsigned i=0;i<64;i++)branches64[i]=0x54000040;
        HvBlock block = {.va=0x10000000, .pa=0x10000000};
        failed += hv_translate_emit(&m,&block,branches64,64)!=0 || block.ninsns!=48;
        block.va=block.pa=0x10003ffc;
        failed += hv_translate_emit(&m,&block,branches64,1)!=0 || block.ninsns!=1;
        block.va=block.pa=0x10000000;
        uint64_t stop=m.stop_pc;m.stop_pc=block.va+4;
        failed += hv_translate_emit(&m,&block,branches64,4)!=0 || block.ninsns!=1;
        m.stop_pc=stop; m.chain=chain;hv_knob[HV_K_SUPERBLOCKS]=saved;
        printf("superblocks: conditional classes, fallthrough, page boundary, 48-insn limit and stop-PC guards checked\n");
    }
    /* PAC: compare against the inputs, with canonical pointers in the registers. */
    {
        static HvCpu init, jit;
        static const TestProgram pac_prog = TEST_PROGRAM(pac);
        memset(&init, 0, sizeof init);
        seed_cpu(&init, 99, sp);
        for (int r = 0; r < 31; r++) init.x[r] = r & 1 ? 0xfffffe0007123450ull + r * 8 : 0x100004000ull + r * 8;
        int bad = run_jit(&m, &pac_prog, &init, &jit, NULL);
        HvCpu want = init;
        want.x[4] = 0;
        want.x[9] = init.x[30];  /* RETAB came back here, so x30 was restored */
        want.x[10] = init.x[30];
        if (!bad) bad = compare_cpus("pac", &want, &jit);
        printf("%-12s       : %s\n", "pac", bad ? "FAIL" : "ok");
        failed += bad != 0;
    }
    /* Again with a JIT region so small that it fills (and everything is flushed)
       in the middle of a program, chains pending and all. */
    {
        static HvMachine small;
        /* Split RX/RW attachment requires >= 4096 bytes. Keep the actual
           mapping valid but expose only 1 KiB to the allocator, including
           after resets (the per-flush limit knob can be reset). */
        if (hv_machine_init(&small, 4096) != 0) {
            printf("small JIT mapping init failed\n");
            return 1;
        }
        size_t mapped_capacity = small.jit.capacity;
        small.jit.capacity = 1024 / sizeof(uint32_t);
        hv_machine_add_ram(&small, (uint64_t)(uintptr_t)jit_programs_begin, jit_programs_finish - jit_programs_begin,
                           (void *)jit_programs_begin, 1);
        hv_machine_add_ram(&small, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
        for (size_t i = 0; i < count; i++) {
            static HvCpu init, native, jit;
            memset(&init, 0, sizeof init);
            seed_cpu(&init, i * 2 + 1, sp);
            run_native(&programs[i], &init, &native, NULL);
            int bad = run_jit(&small, &programs[i], &init, &jit, NULL);
            if (!bad) bad = compare_cpus(programs[i].name, &native, &jit);
            if (bad) printf("%-12s with a full JIT region: FAIL\n", programs[i].name);
            failed += bad != 0;
        }
        printf("with a 1 KB JIT region: %llu flushes\n", (unsigned long long)small.stats.block_flushes);
        failed += small.stats.block_flushes == 0;
        small.jit.capacity = mapped_capacity;
        hv_machine_free(&small);
    }
    /* Again with the code cache a ring of two 32 KB segments (whatever HV_JIT_SEGMENTS says), the programs' pages
       invalidated after every round so they are translated again and the ring comes round about once a round:
       segments taken back in the middle of programs, with exits chained into their blocks from blocks that stay. */
    {
        static HvMachine ring;
        if (hv_machine_init(&ring, 64 << 10) != 0) return 1;
        hv_jit_ring(&ring.jit, 2);
        hv_machine_add_ram(&ring, (uint64_t)(uintptr_t)jit_programs_begin, jit_programs_finish - jit_programs_begin,
                           (void *)jit_programs_begin, 1);
        hv_machine_add_ram(&ring, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
        int bad_rounds = 0;
        for (int round = 0; round < 64; round++) {
            for (size_t i = 0; i < count; i++) {
                static HvCpu init, native, jit;
                memset(&init, 0, sizeof init);
                seed_cpu(&init, i * 2 + 1 + (size_t)round, sp);
                run_native(&programs[i], &init, &native, NULL);
                int bad = run_jit(&ring, &programs[i], &init, &jit, NULL);
                if (!bad) bad = compare_cpus(programs[i].name, &native, &jit);
                if (bad) printf("%-12s with a ring, round %d: FAIL\n", programs[i].name, round);
                bad_rounds += bad != 0;
            }
            uint64_t from = (uint64_t)(uintptr_t)jit_programs_begin & ~16383ull, to = (uint64_t)(uintptr_t)jit_programs_finish;
            for (uint64_t pa = from; pa < to; pa += 16384) hv_invalidate_code(&ring, pa < (uint64_t)(uintptr_t)jit_programs_begin ? (uint64_t)(uintptr_t)jit_programs_begin : pa);
        }
        printf("with a 64 KB ring of %u segments: %llu evictions (%llu blocks dropped, %llu exits unchained), %llu full flushes\n",
               ring.jit.nseg, (unsigned long long)ring.stats.evictions, (unsigned long long)ring.stats.evict_blocks,
               (unsigned long long)ring.stats.evict_unchained, (unsigned long long)ring.stats.block_flushes);
        if (!ring.stats.evictions || !ring.stats.evict_unchained || ring.stats.block_flushes) {
            printf("ring: expected evictions that undo chained exits, and no full flush: FAIL\n");
            bad_rounds++;
        }
        failed += bad_rounds;
    }
    printf("%zu programs x 2 seeds, %d failures, %d blocks translated\n", count, failed, m.nblocks);
    return failed != 0;
}
