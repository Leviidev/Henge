#ifndef HENGE_QUIESCE_WAIT_H
#define HENGE_QUIESCE_WAIT_H
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <errno.h>
#include <time.h>

/* A global code flush must wait for running peers to park. Keep the short
   uncontended spin, then park the host waiter until a peer parks or posts work.
   Public pthread APIs only. This is NOT a guest WFE/WFI or timer policy. */
typedef struct {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    _Alignas(128) _Atomic unsigned waiters;
    _Alignas(128) _Atomic uint64_t waits, timeouts, errors;
} HvQuiesceWait;
static inline int hv_quiesce_init(HvQuiesceWait *q) {
    int rc=pthread_mutex_init(&q->mu,NULL);
    if(rc)return rc;
    rc=pthread_cond_init(&q->cv,NULL);
    if(rc)pthread_mutex_destroy(&q->mu);
    return rc;
}
static inline void hv_quiesce_destroy(HvQuiesceWait *q) {
    pthread_cond_destroy(&q->cv);pthread_mutex_destroy(&q->mu);
}
static inline void hv_quiesce_notify(HvQuiesceWait *q) {
    if(!atomic_load_explicit(&q->waiters,memory_order_seq_cst))return;
    pthread_mutex_lock(&q->mu);pthread_cond_broadcast(&q->cv);pthread_mutex_unlock(&q->mu);
}
/* busy() uses seq_cst publication, checks peers AND the waiter's own pending
   requests. Arm before checking to close the producer's check-to-sleep race.
   One bounded wait lets the caller process its own TLBI requests each time. */
static inline int hv_quiesce_wait(HvQuiesceWait *q,int (*busy)(void *),void *opaque) {
    int rc=0;
    pthread_mutex_lock(&q->mu);
    atomic_fetch_add_explicit(&q->waiters,1,memory_order_seq_cst);
    if(busy(opaque)) {
        atomic_fetch_add_explicit(&q->waits,1,memory_order_relaxed);
#if defined(__APPLE__)
        struct timespec delay={0,100000};
        rc=pthread_cond_timedwait_relative_np(&q->cv,&q->mu,&delay);
#else
        struct timespec until={0};
        timespec_get(&until,TIME_UTC);
        until.tv_nsec+=100000;
        if(until.tv_nsec>=1000000000){until.tv_sec++;until.tv_nsec-=1000000000;}
        rc=pthread_cond_timedwait(&q->cv,&q->mu,&until);
#endif
        if(rc==ETIMEDOUT)atomic_fetch_add_explicit(&q->timeouts,1,memory_order_relaxed);
        else if(rc)atomic_fetch_add_explicit(&q->errors,1,memory_order_relaxed);
    }
    atomic_fetch_sub_explicit(&q->waiters,1,memory_order_seq_cst);
    pthread_mutex_unlock(&q->mu);
    return rc;
}
#endif
