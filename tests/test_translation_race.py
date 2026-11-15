"""Exercise actual dispatch lookup with deterministic concurrent publication.

Only emit/place and platform helpers are substituted: a competing CPU publishes
at controlled points. The real block hash lookup, validation and publication run.
No claim of a full threaded JIT execution test; native engine tests complement it.
"""
from pathlib import Path
import os, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
src = (root / 'core/dispatch.c').read_text()
lookup = src[src.index('static HvBlock *lookup('):src.index('\n/* WFE.', src.index('static HvBlock *lookup('))]
preamble = r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "machine.h"
#define hash_of hv_block_hash
#define find hv_block_find
static HvMachine m;
static HvCpu cpu;
static HvBlock winner, storage[4];
static uint32_t page_gen, words[4096];
static uint8_t protected_page;
static int schedule, emitted, placed, kicks;
static uint64_t mach_absolute_time(void) { return 1; }
static void publish(const HvBlock *b) {
    winner = *b;
    if (schedule == 3) winner.flags ^= HV_BLOCK_PAN;
    if (schedule == 4) winner.gen++;
    winner.code = words;
    /* Same bucket deliberately, to test exact identity and page generation. */
    m.hash[hash_of(b->va, b->pa, b->flags)] = &winner;
}
static int hv_translate_emit(HvMachine *mm, HvBlock *b, const uint32_t *c, uint32_t n) {
    (void)mm; (void)c; (void)n; emitted++;
    if (schedule == 1 || schedule == 3 || schedule == 4) publish(b);
    return 0;
}
static uint32_t hv_translate_pending_words(void) { return 64; }
static int hv_translate_place(HvMachine *mm, HvBlock *b) {
    placed++; b->code = words + 64; mm->jit.used += 64;
    if (schedule == 2) publish(b);
    return 0;
}
static void block_dump(const HvBlock *b, const uint32_t *c) { (void)b; (void)c; }
static void hv_tlb_protect_code_page(HvCpu *c, HvRam *r, uint64_t p) { (void)c; (void)r; (void)p; }
void hv_machine_kick_all(HvMachine *mm) { (void)mm; kicks++; }
'''
main = r'''
int main(void) {
    for (schedule = 0; schedule <= 4; schedule++) {
        memset(&m, 0, sizeof m); memset(&cpu, 0, sizeof cpu);
        memset(&winner, 0, sizeof winner);
        pthread_mutex_init(&m.tr_mu, NULL);
        protected_page = 1; page_gen = 7;
        m.nram = 1; m.ram[0] = (HvRam){.pa=0x80000000, .size=16384,
            .page_gen=&page_gen, .code_pages=&protected_page};
        m.blocks = storage; m.max_blocks = 4; m.jit.base = words;
        cpu.m = &m; cpu.pc_state = &m.percpu[0];
        emitted = placed = kicks = 0;
        HvBlock *b = lookup(&cpu, 0x1000, 0x80000000, HV_BLOCK_EL1, words, 1);
        assert(b && b->flags == HV_BLOCK_EL1 && b->gen == 7);
        assert(emitted == 1 && !kicks);
        if (schedule == 1) {
            assert(b == &winner && !placed && !m.jit.used && !m.nblocks);
            assert(m.stats.duplicate_place_avoided == 1);
            assert(m.stats.duplicate_bytes_avoided == 256);
        } else {
            assert(placed == 1 && m.jit.used == 64);
            assert(!m.stats.duplicate_place_avoided);
            assert(m.stats.duplicate_place_late == (schedule == 2));
            assert(m.nblocks == (schedule != 2));
        }
        assert(lookup(&cpu, 0x1000, 0x80000000, HV_BLOCK_EL1, words, 1) == b);
        assert(emitted == 1); /* front-cache reuse */
        pthread_mutex_destroy(&m.tr_mu);
    }
    puts("translation race: winner before placement saves 256 bytes; late winner, flags, generations and reuse passed");
}
'''
# Include the real RAM-region lookup, without the rest of the Darwin runtime.
msrc = (root / 'core/machine.c').read_text()
a = msrc.index('HvRam *hv_ram_lookup(')
b = msrc.index('\n}', a) + 2
ram_lookup = msrc[a:b]
a = msrc.index('void hv_block_index_add(')
b = msrc.index('\n}', a) + 2
block_index_add = msrc[a:b]
a = src.index('static void request_evict(')
b = src.index('\n}',a)+2
request_evict = src[a:b]
with tempfile.TemporaryDirectory() as tmp:
    c = Path(tmp) / 'race.c'; c.write_text(preamble + ram_lookup + '\n' + block_index_add + '\n' + request_evict + '\n' + lookup + main)
    exe = Path(tmp) / 'race'
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-O2', '-pthread',
                    '-I' + str(root/'core'), '-I' + str(root/'host'), str(c), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
