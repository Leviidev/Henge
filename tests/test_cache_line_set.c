#include "cache_line_set.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    uintptr_t base=0x100000;size_t bytes=1<<20,words=hv_cache_line_bitmap_words(bytes);
    uint64_t *bits=malloc(words*sizeof *bits);uint32_t **sites=malloc(65536*sizeof *sites);assert(bits&&sites);
    for(size_t i=0;i<65536;i++)sites[i]=(uint32_t *)(base+((i*17)%256)*4);
    assert(hv_cache_line_mark(bits,words,base,bytes,sites,65536));
    unsigned total=0;for(size_t i=0;i<words;i++)total+=(unsigned)__builtin_popcountll(bits[i]);
    assert(total==16);
    sites[2]=(uint32_t *)(base+bytes-4);
    assert(hv_cache_line_mark(bits,words,base,bytes,sites,65536)&&bits[words-1]>>63);
    sites[2]=(uint32_t *)(base+bytes);assert(!hv_cache_line_mark(bits,words,base,bytes,sites,65536));
    sites[2]=(uint32_t *)(base-4);assert(!hv_cache_line_mark(bits,words,base,bytes,sites,65536));
    assert(!hv_cache_line_mark(NULL,words,base,bytes,sites,65536));
    assert(!hv_cache_line_mark(bits,words,UINTPTR_MAX-63,4096,sites,65536));
    assert(!hv_cache_line_bitmap_words(SIZE_MAX));
    free(bits);free(sites);
    puts("PASS JIT dirty lines:65536 unordered writes ->16 exact lines; final word, outside range, allocation fallback and overflow bounds");
}
