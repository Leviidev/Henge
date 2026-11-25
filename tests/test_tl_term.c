/* The terminal for command-line Mac programs (ios/Henge/Native/henge-tl-term.c) on the Mac, under iOS's rules:
   test_tl_term OUT SECONDS KEYS PROGRAM [ARGS...] runs the program in an 80 by 40 terminal, types KEYS half way ("\r"
   for Return), and writes what it drew to OUT. */
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "henge-ios-jit.h"
#include "henge-tl.h"
#include "jit_region.h"

static HvJitRegion jit;
static HengeDualMapping mapping;
_Atomic int henge_tl_ran;
int henge_vm_state(void) { return 0; }
HengeDualMapping *henge_ios_jit_get_mapping(void) { return &mapping; }
static FILE *out;
static _Atomic int done;
static void output(const char *b, size_t n) { fwrite(b, 1, n, out); fflush(out); }
static void open_url(const char *u) { fprintf(stderr, "test_tl_term: wants a page opened (%.30s...)\n", u); }
static void ended(int code) { fprintf(stderr, "test_tl_term: ended with %d\n", code); atomic_store(&done, 1); }

int main(int argc, char **argv) {
    if (argc < 5) return 2;
    if (!(out = fopen(argv[1], "w"))) return 2;
    setenv("HV_JIT_SPLIT", "1", 1); /* the iOS shape */
    if (hv_jit_region_open(&jit, (size_t)1200 << 20)) { fprintf(stderr, "no JIT region\n"); return 2; }
    mapping = (HengeDualMapping){.rx_addr = (uint8_t *)jit.base, .rw_addr = (uint8_t *)jit.base + jit.rw_diff, .size = jit.capacity * 4};
    char err[512] = "";
    const char *env[] = {"TERM=xterm-256color", "BUN_JSC_useJIT=0", NULL};
    if (henge_tl_term_start(argv[4], (const char *const *)argv + 5, env, NULL, 80, 40, output, open_url, ended, err, sizeof err)) {
        fprintf(stderr, "test_tl_term: %s\n", err);
        return 1;
    }
    int tenths = (int)(atof(argv[2]) * 10);
    for (int i = 0; i < tenths && !atomic_load(&done); i++) {
        usleep(100000);
        if (i == tenths / 2) {
            char keys[512];
            size_t n = 0;
            for (const char *p = argv[3]; *p && n < sizeof keys; p++) {
                if (p[0] == '\\' && p[1] == 'r') keys[n++] = '\r', p++;
                else keys[n++] = *p;
            }
            henge_tl_term_write(keys, n);
            henge_tl_term_resize(60, 30);
        }
    }
    fclose(out);
    _exit(0);
}
