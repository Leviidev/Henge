#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "machine.h"

int main(void) {
    static HvMachine m;
    static unsigned char bytes[4096];
    const uint64_t bases[] = {0x80000000ull, UINT64_MAX - 4095};
    m.nram = 1;
    for (unsigned k = 0; k < sizeof bases / sizeof bases[0]; k++) {
        uint64_t base = bases[k];
        m.ram[0] = (HvRam){.pa = base, .size = sizeof bytes, .host = bytes};
        assert(hv_phys_ptr(&m, base, sizeof bytes) == bytes);
        assert(hv_phys_ptr(&m, base + 4095, 1) == bytes + 4095);
        assert(hv_phys_ptr(&m, base + 8, 4088) == bytes + 8);
        assert(hv_phys_ptr(&m, base, 0) == bytes);
        assert(hv_phys_ptr(&m, base + 4095, 2) == NULL);
        assert(hv_phys_ptr(&m, base + 8, 4089) == NULL);
        assert(hv_phys_ptr(&m, base + 8, UINT64_MAX) == NULL);
        assert(hv_phys_ptr(&m, base, UINT64_MAX) == NULL);
    }
    puts("guest RAM span boundaries and uint64 overflow rejection tests passed");
}
