#include "jit_region.h"

#include <stdio.h>
#include <stdlib.h>

/* Both shapes: macOS MAP_JIT, and the iOS split mapping (RX plus an RW alias). */
static int one(const char *what) {
    HvJitRegion region;
    if (hv_jit_region_open(&region, 1 << 20) != 0) {
        printf("%s: could not map the JIT region\n", what);
        return 1;
    }
    uint32_t *code = hv_jit_reserve(&region, 2);
    static const uint32_t body[2] = {0xd2800540, 0xd65f03c0}; /* mov x0, #42; ret */
    hv_jit_write(&region, code, body, sizeof body);
    hv_jit_finish(&region, code, 2);
    long (*fn)(void) = (long (*)(void))code;
    long got = fn();
    printf("%s: jit region returned %ld\n", what, got);
    // Two discontiguous code ranges must both become executable through the
    // RX alias. A later B-to-B patch is entered after a context sync, as the
    // dispatcher does. Exercise both MAP_JIT and the split-alias shape.
    uint32_t *site = hv_jit_reserve(&region, 66);
    uint32_t *a = site + 16, *b = site + 32;
    const uint32_t second[2] = {0xd2800560, 0xd65f03c0}; // mov x0,#43; ret
    hv_jit_write(&region, a, body, sizeof body);
    hv_jit_write(&region, b, second, sizeof second);
    hv_jit_finish2(&region, a, 2, b, 2);
    uint32_t branch = 0x14000010;
    hv_jit_write(&region, site, &branch, 4); hv_jit_finish(&region, site, 1);
    long (*jump)(void) = (long (*)(void))site;
    int bad = got != 42 || jump() != 42;
    branch = 0x14000020;
    hv_jit_write(&region, site, &branch, 4); hv_jit_finish_branch(&region, site);
    __asm__ volatile("isb" ::: "memory");
    bad |= jump() != 43;
    uint32_t **patches=malloc(65536*sizeof *patches);
    if(!patches) return 1;
    for(size_t i=0;i<65536;i++)patches[i]=i&1?a:b;
    hv_jit_write(&region,a,second,sizeof second);hv_jit_write(&region,b,body,sizeof body);
    hv_jit_finish_words(&region,patches,65536);
    __asm__ volatile("isb" ::: "memory");
    bad |= ((long(*)(void))a)()!=43 || ((long(*)(void))b)()!=42 || region.publication_bitmap_batches!=1;
    free(patches);
    uint32_t *small[2]={a,b};
    hv_jit_write(&region,a,body,sizeof body);hv_jit_write(&region,b,second,sizeof second);
    hv_jit_finish_words(&region,small,2);
    __asm__ volatile("isb" ::: "memory");
    bad |= ((long(*)(void))a)()!=42 || ((long(*)(void))b)()!=43 || region.publication_bitmap_batches!=1;
    printf("%s: bitmap publication65536 writes / %llu exact RX lines %s\n",what,(unsigned long long)region.publication_lines,bad?"FAIL":"passed");
    printf("%s: two-range publication and B-to-B patch %s\n", what, bad ? "FAIL" : "passed");
    hv_jit_region_close(&region);
    return bad;
}

int main(void) {
    int bad = one("MAP_JIT");
    setenv("HV_JIT_SPLIT", "1", 1);
    bad |= one("split");
    return bad;
}
