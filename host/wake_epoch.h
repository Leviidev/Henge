#ifndef HENGE_WAKE_EPOCH_H
#define HENGE_WAKE_EPOCH_H
#include <stdatomic.h>
#include <stdint.h>

/* One generation per start/stop; a new VM cannot revive an old sleeping worker. */
typedef struct HvWakeEpoch { _Atomic uint64_t value; } HvWakeEpoch;
static inline uint64_t hv_wake_advance(HvWakeEpoch *e) {
    return atomic_fetch_add_explicit(&e->value, 1, memory_order_acq_rel) + 1;
}
static inline int hv_wake_current(HvWakeEpoch *e, uint64_t token) {
    return atomic_load_explicit(&e->value, memory_order_acquire) == token;
}
#endif
