#include "machine.h"
#include "dispatch.h"
#include <mach/mach_time.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HvMachine m;
static HvCpu cpu;
/* LDR X1,[X0]; ADD X2,X2,X1; SUBS X3,X3,#1; B.NE loop */
static uint32_t code[4096] __attribute__((aligned(16384))) = {0xf9400001, 0x8b010042, 0xf1000463, 0x54ffffa1};
static uint64_t code_words(void) { return m.stats.words_inline + m.stats.words_ool + m.stats.words_pool; }
int main(void) {
    assert(hv_machine_init(&m, 4 << 20) == 0);
    unsigned char *data = aligned_alloc(16384, 32768);
    assert(data);
    assert(hv_machine_add_ram(&m, (uintptr_t)code, sizeof code, code, 1) == 0);
    assert(hv_machine_add_ram(&m, (uintptr_t)data, 32768, data, 0) == 0);
    m.stats_interval = 1000;
    mach_timebase_info_data_t timebase;
    assert(mach_timebase_info(&timebase) == 0);
    for (int width=8; width<=16; width+=8) {
        code[0] = width==8 ? 0xf9400001 : 0xa9401001; /* LDR X1 or LDP X1,X4 */
        uint64_t middle_words = 0;
        for (int scenario=0; scenario<3; scenario++) {
            for (int precise=0; precise<=1; precise++) {
                hv_knob[HV_K_RECHECK] = precise;
                hv_flush_blocks(&m);
                hv_cpu_reset(&cpu, &m);
                memset(data, 0, 32768);
                size_t offset = scenario==0 ? 64 : scenario==1 ? 16384-width : 16384-width+4;
                uint64_t value = 5;
                memcpy(data+offset, &value, sizeof value);
                uint64_t second = 7;
                if (width==16) memcpy(data+offset+8, &second, sizeof second);
                cpu.pc = (uintptr_t)code;
                cpu.x[0] = (uintptr_t)(data+offset);
                cpu.x[3] = 100000;
                cpu.cpacr_el1 = 3u << 20;
                m.stop_pc = (uintptr_t)(code+4);
                m.stat_slow_mem = 0;
                uint64_t words_before = code_words(), start = mach_absolute_time();
                assert(hv_run(&cpu) == HV_EXIT_HALT);
                uint64_t elapsed = mach_absolute_time()-start;
                assert(cpu.x[2] == 500000 && cpu.x[3] == 0);
                if (width==16) assert(cpu.x[4] == 7);
                uint64_t slow = m.stat_slow_mem;
                if (scenario==1) assert(width==16 || precise ? slow <= 1 : slow == 100000);
                if (scenario==2) assert(slow == 100000); /* a real crossing must remain slow */
                uint64_t words = code_words()-words_before;
                if (scenario==0 && !precise) middle_words = words;
                if (scenario==0 && precise && width==16) assert(words==middle_words); /* 16-byte guard is already exact */
                double ns = (double)elapsed*timebase.numer/timebase.denom;
                printf("tail-recheck: bytes=%d location=%s enabled=%d slow_helpers=%llu/100000 ns_per_iteration=%.1f emitted_words=%llu\n",
                    width, scenario==0 ? "middle" : scenario==1 ? "valid-tail" : "cross-page",
                    precise, (unsigned long long)slow, ns/100000, (unsigned long long)(code_words()-words_before));
            }
        }
    }
    hv_machine_free(&m);
    free(data);
    puts("tail recheck: identical guest results, valid page-tail helpers removed, real page crossing preserved");
}
