#ifndef HENGE_SURFACE_HASH_H
#define HENGE_SURFACE_HASH_H
#include <stdint.h>
#include <string.h>
/* Full-byte content signature. Independent lanes avoid one serial multiply
   per word. Unaligned reads and tails are safe; never sample/skip pixels. */
static uint64_t hv_surface_hash(const uint8_t *p, uint64_t n) {
    uint64_t a=0xcbf29ce484222325ull, b=0x9e3779b97f4a7c15ull;
    uint64_t c=0x94d049bb133111ebull, d=0x2545f4914f6cdd1dull;
    uint64_t left=n;
    while (left>=32) {
        uint64_t v[4]; memcpy(v,p,32);
        a=(a^v[0])*0x100000001b3ull; b=(b^v[1])*0x100000001b3ull;
        c=(c^v[2])*0x100000001b3ull; d=(d^v[3])*0x100000001b3ull;
        p+=32; left-=32;
    }
    uint64_t h=a ^ (b<<13|b>>51) ^ (c<<29|c>>35) ^ (d<<47|d>>17) ^ n;
    while (left--) h=(h^*p++)*0x100000001b3ull;
    return h;
}
#endif
