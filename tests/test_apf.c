// Apple's x86 flags (PF in NZCV bit 26, AF in bit 27) for threads with ACTLR_EL1.EnAPFLG: the JIT against the native
// run plus a model of what the extension puts there (see core/translate.c for what it was measured to do).
#include "harness.h"

#include <stdlib.h>

#include "sysreg.h"

DECLARE_PROGRAM(apf_cases);
DECLARE_PROGRAM(apf_stolen);
DECLARE_PROGRAM(apf_branch);
extern const char apf_programs_begin[], apf_programs_finish[];

#define PF HV_NZCV_PF
#define AF HV_NZCV_AF

static uint64_t parity(uint64_t r) { return __builtin_popcount((unsigned)(r & 0xff)) & 1 ? 0 : PF; }
static uint64_t arith(uint64_t a, uint64_t b, uint64_t r) { return parity(r) | (((a ^ b ^ r) >> 4) & 1 ? AF : 0); }

static int el0_apf;
static void setup(HvCpu *cpu) {
    cpu->el = 0, cpu->spsel = 0;
    cpu->actlr_el1 = el0_apf ? 0x72 : 0;
}

typedef struct { int reg; uint64_t want; } Want;

static int check(const char *name, const HvCpu *native, const HvCpu *jit, const Want *w, int n, int apf) {
    int bad = 0;
    for (int i = 0; i < n; i++) {
        uint64_t want = apf ? w[i].want : native->x[w[i].reg];
        if (jit->x[w[i].reg] != want) {
            printf("  %s: x%d jit %08llx want %08llx\n", name, w[i].reg, (unsigned long long)jit->x[w[i].reg], (unsigned long long)want);
            bad++;
        }
    }
    return bad;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    static HvMachine m;
    if (hv_machine_init(&m, 4 << 20) != 0) return 1;
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)apf_programs_begin, apf_programs_finish - apf_programs_begin, (void *)apf_programs_begin, 1);
    uint8_t *stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
    int failed = 0;
    for (int seed = 1; seed <= 40; seed++) {
        static HvCpu init, native, jit;
        memset(&init, 0, sizeof init);
        uint64_t sp = (uint64_t)(uintptr_t)stack + 32768 + (seed & 15) * 16 + (seed & 16 ? 0x100 : 0);
        seed_cpu(&init, (uint64_t)seed * 7919, sp);
        if (seed > 20) /* small values too, so that carries out of bit 3 and zero low bytes come up */
            for (int r = 0; r < 31; r++) init.x[r] &= seed & 1 ? 0xff : 0x3f;
        if (seed % 3 == 0) init.x[2] = 0; /* apf_branch's CBZ taken */
        init.nzcv = (uint64_t)(seed & 15) << 28;
        const uint64_t *x = init.x;
        for (el0_apf = 1; el0_apf >= 0; el0_apf--) {
            /* apf_cases */
            run_native(&(TestProgram)TEST_PROGRAM(apf_cases), &init, &native, NULL);
            int bad = run_jit(&m, &(TestProgram)TEST_PROGRAM(apf_cases), &init, &jit, setup);
            if (!bad) {
                uint32_t w2 = (uint32_t)x[2], w3 = (uint32_t)x[3], w4 = (uint32_t)x[4], w5 = (uint32_t)x[5];
                uint64_t c6 = (native.x[24] >> 29) & 1, c7 = (native.x[25] >> 29) & 1;
                uint64_t b6 = (uint64_t)(int64_t)(int8_t)x[2] << 2;
                Want w[] = {
                    {19, native.x[19] | arith(x[0], x[1], x[0] + x[1])},
                    {20, native.x[20] | arith(w2, w3, (uint32_t)(w2 - w3))},
                    {21, native.x[21] | arith(x[6], x[7], x[6] - x[7])},
                    {22, native.x[22] | arith(sp, 0x123, sp + 0x123)},
                    {23, native.x[23] | arith(w4, (uint32_t)(w5 << 3), (uint32_t)(w4 - (w5 << 3)))},
                    {24, native.x[24] | arith(x[0], b6, x[0] + b6)},
                    {25, native.x[25] | arith(x[1], x[15], x[1] + x[15] + c6)},
                    {26, native.x[26] | arith(w3, (uint32_t)x[28], (uint32_t)(w3 - (uint32_t)x[28] - (1 - c7)))},
                    {27, native.x[27] | parity(x[0] & x[1])},
                    {29, native.x[29] | parity(w4 & 0xff)},
                    {30, native.x[30] | parity(x[5] & ~x[28])},
                    {9, native.x[9] | arith(0, x[2], 0 - x[2])},
                    {10, native.x[10] | arith(x[2], x[3], x[2] - x[3])},
                    {11, 0x6c000000},
                    {12, native.x[12] | arith(x[0], x[1], x[0] + x[1])},
                    {13, native.x[13] | PF},
                    {14, native.x[14] | arith(x[0], x[1], x[0] + x[1])},
                    {16, native.x[16] | arith((uint32_t)x[0], 0x10, (uint32_t)((uint32_t)x[0] + 0x10))},
                    {17, native.x[17] | arith(x[6], x[6] >> 3, x[6] + (x[6] >> 3))},
                };
                bad = check("apf_cases", &native, &jit, w, sizeof w / sizeof *w, el0_apf);
                /* Everything else as natively; NZCV's N, Z, C, V too. */
                HvCpu nat2 = native;
                for (unsigned i = 0; i < sizeof w / sizeof *w; i++) nat2.x[w[i].reg] = jit.x[w[i].reg];
                bad += compare_cpus("apf_cases", &nat2, &jit);
            }
            if (bad) printf("apf_cases seed %d %s: FAIL\n", seed, el0_apf ? "EnAPFLG" : "plain");
            failed += bad != 0;

            /* apf_stolen */
            run_native(&(TestProgram)TEST_PROGRAM(apf_stolen), &init, &native, NULL);
            bad = run_jit(&m, &(TestProgram)TEST_PROGRAM(apf_stolen), &init, &jit, setup);
            if (!bad) {
                Want w[] = {
                    {6, 0x08000000},
                    {15, native.x[15] | arith(x[0], x[1], x[0] + x[1])},
                    {9, x[28] & 0xfc000000},
                    {10, native.x[10] | arith(x[28], x[3], x[28] - x[3])},
                    {11, native.x[11]},
                };
                bad = check("apf_stolen", &native, &jit, w, sizeof w / sizeof *w, el0_apf);
                HvCpu nat2 = native;
                for (unsigned i = 0; i < sizeof w / sizeof *w; i++) nat2.x[w[i].reg] = jit.x[w[i].reg];
                bad += compare_cpus("apf_stolen", &nat2, &jit);
            }
            if (bad) printf("apf_stolen seed %d %s: FAIL\n", seed, el0_apf ? "EnAPFLG" : "plain");
            failed += bad != 0;

            /* apf_branch */
            run_native(&(TestProgram)TEST_PROGRAM(apf_branch), &init, &native, NULL);
            bad = run_jit(&m, &(TestProgram)TEST_PROGRAM(apf_branch), &init, &jit, setup);
            if (!bad) {
                Want w[] = {
                    {20, native.x[20] | (x[2] ? arith(x[2], x[3], x[2] - x[3]) : arith(x[0], x[1], x[0] + x[1]))},
                    {22, native.x[22] | (x[4] & 1 ? arith(x[0], x[2], x[0] - x[2]) : parity(x[1] & x[3]))},
                    {23, native.x[23] | arith(x[0], x[3], x[0] + x[3])},
                };
                bad = check("apf_branch", &native, &jit, w, sizeof w / sizeof *w, el0_apf);
                HvCpu nat2 = native;
                for (unsigned i = 0; i < sizeof w / sizeof *w; i++) nat2.x[w[i].reg] = jit.x[w[i].reg];
                bad += compare_cpus("apf_branch", &nat2, &jit);
            }
            if (bad) printf("apf_branch seed %d %s: FAIL\n", seed, el0_apf ? "EnAPFLG" : "plain");
            failed += bad != 0;
        }
    }
    /* S3_6_C15_C8_3 (APSTATE): bit 1 PF, bit 2 AF, as the kernel saves and restores them. */
    {
        static HvCpu c;
        hv_cpu_reset(&c, &m);
        if (hv_apf_get(&c) != 0) { printf("reset: PF/AF %llx\n", (unsigned long long)hv_apf_get(&c)); failed++; }
        uint32_t msr = 0xd51ef868, mrs = 0xd53ef869; /* msr s3_6_c15_c8_3, x8; mrs x9, s3_6_c15_c8_3 */
        for (uint64_t v = 0; v < 8; v++) {
            c.x[8] = v | 0xf0;
            hv_sysreg_msr(&c, msr, 0);
            c.x[9] = ~0ull;
            hv_sysreg_mrs(&c, mrs, 0);
            uint64_t want = v & 6;
            if (c.x[9] != want || hv_apf_get(&c) != want << 25) {
                printf("APSTATE %llx: read %llx, flags %llx\n", (unsigned long long)v, (unsigned long long)c.x[9], (unsigned long long)hv_apf_get(&c));
                failed++;
            }
        }
    }
    /* Snapshots keep PF and AF in NZCV bits 26 and 27 (host/snapshot.c): every combination comes back, N Z C V too,
       and an older snapshot's NZCV (bits 26 and 27 clear) gives them clear. */
    {
        static HvCpu a, b;
        hv_cpu_reset(&a, &m);
        hv_cpu_reset(&b, &m);
        for (uint64_t v = 0; v < 64; v++) {
            a.nzcv = (v & 15) << 28;
            hv_apf_set(&a, (v >> 4) << 26);
            uint64_t saved = hv_nzcv_save(&a);
            hv_nzcv_restore(&b, saved);
            if (b.nzcv != a.nzcv || hv_apf_get(&b) != hv_apf_get(&a) || hv_apf_get(&a) != ((v >> 4) & 3) << 26) {
                printf("snapshot NZCV %llx: nzcv %llx flags %llx\n", (unsigned long long)v, (unsigned long long)b.nzcv,
                       (unsigned long long)hv_apf_get(&b));
                failed++;
            }
        }
        hv_apf_set(&b, HV_NZCV_PF | HV_NZCV_AF);
        hv_nzcv_restore(&b, 0x60000000);
        if (b.nzcv != 0x60000000 || hv_apf_get(&b) != 0) { printf("old snapshot: PF/AF not clear\n"); failed++; }
    }
    printf("apf: 40 seeds x 3 programs x (EnAPFLG, plain), %d failures, %d blocks translated\n", failed, m.nblocks);
    return failed != 0;
}
