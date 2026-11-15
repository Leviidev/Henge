#ifndef HENGE_FASTMEM_H
#define HENGE_FASTMEM_H

#include "cpu.h"
#include <stdio.h>

/* Bounded, tagged kernel read LUT; all canonical kernel windows share the
   same direct-mapped slots. Exact VA tags make collisions ordinary misses.
   PAN views remain separate; stores, EL0, MMIO and small pages use the TLB. */
typedef struct HvFastmemEntry { uint64_t tag, addend; } HvFastmemEntry;
_Static_assert(sizeof(HvFastmemEntry) == 16, "Fastmem JIT entry stride");
#define HV_FASTMEM_BITS 32
#define HV_FASTMEM_SIZE (1ull << HV_FASTMEM_BITS)
#define HV_FASTMEM_PAGES (HV_FASTMEM_SIZE >> HV_TLB_PAGE_BITS)

struct HvFastmem;
int hv_fastmem_attach(HvCpu *cpu, struct HvFastmem **owner, int enabled);
void hv_fastmem_free(struct HvFastmem *fm);
/* Scalar only: called with the guest's SIMD registers live. */
void hv_fastmem_fill(HvCpu *cpu, uint64_t va, int table, uint64_t addend);
void hv_fastmem_clear(HvCpu *cpu);
void hv_fastmem_drop(HvCpu *cpu, uint64_t va, uint64_t len);
/* Reference for the JIT guard, also used by the policy tests. */
void *hv_fastmem_read_ptr(HvCpu *cpu, uint64_t va, unsigned bytes, int table);
typedef struct HvFastmemSnapshot {
    uint64_t base, fills, clears, drops, saturated, reanchors;
} HvFastmemSnapshot;
int hv_fastmem_snapshot(HvCpu *cpu, HvFastmemSnapshot *out);
struct HvMachine;
/* Call outside translated code, with host FP/SIMD state restored. */
void hv_fastmem_log(struct HvMachine *m, FILE *out);

#endif
