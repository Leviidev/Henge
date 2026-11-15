#ifndef HENGE_CACHE_LINE_SET_H
#define HENGE_CACHE_LINE_SET_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
/* A quiescent publication batch, indexed by 64-byte RX cache line. Storage
   is bounded separately by the caller; no guest access-path state is cached. */
static inline size_t hv_cache_line_bitmap_words(size_t bytes) {
    if (!bytes || bytes > SIZE_MAX-4095) return 0;
    return (bytes+4095)/4096;
}
static inline int hv_cache_line_mark(uint64_t *bits,size_t count,uintptr_t base,size_t bytes,
                                     uint32_t *const *sites,size_t n) {
    size_t need=hv_cache_line_bitmap_words(bytes);
    if(!bits || !need || count<need || (base&63) || !sites || bytes>UINTPTR_MAX-base)return 0;
    memset(bits,0,need*sizeof *bits);
    for(size_t i=0;i<n;i++) {
        uintptr_t site=(uintptr_t)sites[i];
        if(site<base || site-base>=bytes || (site&3))return 0;
        size_t line=(site-base)>>6;
        bits[line>>6]|=1ull<<(line&63);
    }
    return 1;
}
#endif
