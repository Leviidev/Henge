#ifndef HENGE_IDLE_TICKER_H
#define HENGE_IDLE_TICKER_H
#include <pthread.h>
#include <stdatomic.h>
#include "wake_epoch.h"

typedef struct HvIdleTicker {
    HvWakeEpoch epoch;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    /* Keep the read-mostly unpark check off both mutex and metric cache lines.
       Conservative 128-byte separation also covers smaller cache lines. */
    _Alignas(128) _Atomic unsigned waiters;
    _Alignas(128) _Atomic uint64_t sleeps;
    _Atomic uint64_t resumes, ticks, marked_cpus;
} HvIdleTicker;
#define HV_IDLE_TICKER_INITIALIZER { .mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER }

static inline void hv_idle_ticker_notify(void *opaque) {
    HvIdleTicker *t = opaque;
    if (!atomic_load_explicit(&t->waiters, memory_order_seq_cst)) return;
    pthread_mutex_lock(&t->mu);
    pthread_cond_broadcast(&t->cv);
    pthread_mutex_unlock(&t->mu);
}
static inline uint64_t hv_idle_ticker_advance(HvIdleTicker *t) {
    uint64_t token = hv_wake_advance(&t->epoch);
    hv_idle_ticker_notify(t);
    return token;
}
/* active() and the CPU's active publication must use seq_cst atomics. Arm the
   waiter BEFORE checking active, closing the check-to-sleep lost-wakeup window.
   Multiple generations may overlap briefly during stop/start, hence a count. */
static inline int hv_idle_ticker_wait(HvIdleTicker *t, uint64_t token,
                                     int (*active)(void *), void *opaque) {
    if (!hv_wake_current(&t->epoch, token)) return 0;
    if (active(opaque)) return 1;
    pthread_mutex_lock(&t->mu);
    atomic_fetch_add_explicit(&t->waiters, 1, memory_order_seq_cst);
    while (hv_wake_current(&t->epoch, token) && !active(opaque)) {
        atomic_fetch_add_explicit(&t->sleeps, 1, memory_order_relaxed);
        pthread_cond_wait(&t->cv, &t->mu);
    }
    atomic_fetch_sub_explicit(&t->waiters, 1, memory_order_seq_cst);
    pthread_mutex_unlock(&t->mu);
    atomic_fetch_add_explicit(&t->resumes, 1, memory_order_relaxed);
    return hv_wake_current(&t->epoch, token);
}
#endif
