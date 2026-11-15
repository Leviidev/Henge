#ifndef HENGE_RESOURCE_POLICY_H
#define HENGE_RESOURCE_POLICY_H
#include <stdint.h>
/* A budget for reclaimable host cache ownership, never for live guest RAM,
   framebuffer pixels or executable JIT mappings. Unknown headroom is UINT64_MAX. */
typedef struct { uint64_t library_bytes; unsigned library_entries; int pressure; } HvResourceBudget;
static inline HvResourceBudget hv_resource_budget(uint64_t available, int pressure) {
    if (available < (128ull << 20)) pressure = 2;
    else if (available < (512ull << 20) && pressure < 1) pressure = 1;
    if (pressure < 0) pressure = 0;
    if (pressure > 2) pressure = 2;
    return (HvResourceBudget){pressure == 2 ? 0 : (pressure == 1 ? 2ull : 8ull) << 20,
                             pressure == 2 ? 0u : pressure == 1 ? 8u : 32u, pressure};
}
/* Only the verified ten-core/16GB M4 profile may expand discretionary cache
   ownership, and only with known dynamic headroom. Pressure always wins. */
static inline HvResourceBudget hv_resource_budget_profile(uint64_t available,int pressure,int m4_16gb) {
    HvResourceBudget budget=hv_resource_budget(available,pressure);
    if (m4_16gb && !budget.pressure && available!=UINT64_MAX && available>=(2ull<<30)) {
        budget.library_bytes=16ull<<20;
        budget.library_entries=128;
    }
    return budget;
}
/* Keep a smaller useful presentation pool for a moderate warning. Critical
   system pressure or low process allowance still disables optional upscaling.
   This is the existing cache controller, not another memory/thermal policy. */
static inline unsigned hv_desktop_fx_limit(uint64_t available,int pressure) {
    if(pressure>=2 || available<(512ull<<20))return 0;
    return pressure>0 ? 2 : 3;
}
#endif
