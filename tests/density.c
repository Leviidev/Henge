/* Translated-code density on real compiled code: translates every block of an arm64 Mach-O's
   __TEXT,__text (as EL0 user code, guest VA = file VA) and reports host words per guest
   instruction, hot / cold / pool, and inline words by instruction kind. Nothing runs.
   Usage: build/density <mach-o> [more...]. Env knobs (HV_*) apply as in hengevm. */
#include <fcntl.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libkern/OSByteOrder.h>

#include "classify.h"
#include "cpu.h"
#include "machine.h"
#include "translate.h"

static const char *kind_name[16] = {"copy", "pcrel", "branch", "branch_reg", "eret", "load_lit", "memory", "prefetch",
                                    "exception", "sysreg", "sys", "barrier", "wait", "pac", "undefined", "?"};

static const uint8_t *arm64_slice(const uint8_t *p, size_t n) {
    uint32_t magic = *(const uint32_t *)p;
    if (magic == MH_MAGIC_64) return p;
    if (OSSwapBigToHostInt32(magic) == FAT_MAGIC) {
        const struct fat_header *fh = (const void *)p;
        const struct fat_arch *fa = (const void *)(fh + 1);
        for (uint32_t i = 0; i < OSSwapBigToHostInt32(fh->nfat_arch); i++)
            if ((cpu_type_t)OSSwapBigToHostInt32(fa[i].cputype) == CPU_TYPE_ARM64 && OSSwapBigToHostInt32(fa[i].offset) < n)
                return p + OSSwapBigToHostInt32(fa[i].offset);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <arm64 mach-o>...\n", argv[0]);
        return 2;
    }
    static HvMachine m;
    if (hv_machine_init(&m, 64 << 20) != 0) return 1;
    m.chain = 1;
    m.stats_interval = 1; /* collect words by part and by kind */
    uint64_t insns = 0, blocks = 0, failed = 0;
    for (int a = 1; a < argc; a++) {
        int fd = open(argv[a], O_RDONLY);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) != 0) { perror(argv[a]); continue; }
        const uint8_t *file = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        const uint8_t *mh = file == MAP_FAILED ? NULL : arm64_slice(file, (size_t)st.st_size);
        if (!mh) { fprintf(stderr, "%s: no arm64 slice\n", argv[a]); continue; }
        const struct mach_header_64 *h = (const void *)mh;
        const uint8_t *lc = (const uint8_t *)(h + 1);
        for (uint32_t c = 0; c < h->ncmds; c++, lc += ((const struct load_command *)lc)->cmdsize) {
            if (((const struct load_command *)lc)->cmd != LC_SEGMENT_64) continue;
            const struct segment_command_64 *sg = (const void *)lc;
            const struct section_64 *sec = (const void *)(sg + 1);
            for (uint32_t s = 0; s < sg->nsects; s++) {
                if (strcmp(sec[s].sectname, "__text") || strcmp(sec[s].segname, "__TEXT")) continue;
                const uint32_t *code = (const uint32_t *)(mh + sec[s].offset);
                uint64_t va = sec[s].addr, n = sec[s].size / 4;
                printf("%s: __text %llu instructions at %llx\n", argv[a], (unsigned long long)n, (unsigned long long)va);
                for (uint64_t i = 0; i < n;) {
                    uint64_t pc = va + 4 * i;
                    uint64_t page_end = (pc | ((1ull << HV_TLB_PAGE_BITS) - 1)) + 1;
                    uint32_t avail = (uint32_t)((page_end - pc) / 4);
                    if (avail > n - i) avail = (uint32_t)(n - i);
                    HvBlock b = {.va = pc, .pa = pc, .flags = 0};
                    m.nslots = 0; /* never placed: reuse the chain slots */
                    if (hv_translate_emit(&m, &b, code + i, avail) != 0 || !b.ninsns) {
                        failed++;
                        i++;
                        continue;
                    }
                    blocks++;
                    insns += b.ninsns;
                    i += b.ninsns;
                }
            }
        }
        munmap((void *)file, (size_t)st.st_size);
        close(fd);
    }
    if (!insns) return 1;
    const HvStats *t = &m.stats;
    double hot = (double)t->words_inline, cold = (double)t->words_ool, pool = (double)t->words_pool;
    printf("%llu blocks, %llu guest instructions (%.1f per block), %llu failed\n", (unsigned long long)blocks,
           (unsigned long long)insns, (double)insns / blocks, (unsigned long long)failed);
    printf("host words per guest instruction: hot %.2f  cold %.2f  pool %.2f  total %.2f\n", hot / insns, cold / insns,
           pool / insns, (hot + cold + pool) / insns);
    printf("%-11s %9s %6s %10s\n", "kind", "insns", "share", "hot w/insn");
    for (int k = 0; k < 16; k++)
        if (t->kind_insns[k])
            printf("%-11s %9llu %5.1f%% %10.2f\n", kind_name[k], (unsigned long long)t->kind_insns[k],
                   100.0 * t->kind_insns[k] / insns, (double)t->kind_words[k] / t->kind_insns[k]);
    return 0;
}
