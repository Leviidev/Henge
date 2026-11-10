#ifndef HENGE_LIFECYCLE_GATE_H
#define HENGE_LIFECYCLE_GATE_H
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <time.h>
/* Gate publishers never acquire the waiter mutex or wait for GPU completion.
   Timed wait closes the signal/check race because publishers do not take mu. */
typedef struct {
    _Atomic int active, cancelled;
    pthread_mutex_t mu;
    pthread_cond_t cv;
} HvLifecycleGate;
#define HV_LIFECYCLE_INITIALIZER { .active=1, .cancelled=0, .mu=PTHREAD_MUTEX_INITIALIZER, .cv=PTHREAD_COND_INITIALIZER }
extern HvLifecycleGate hv_app_lifecycle;
extern HvLifecycleGate hv_cpu_lifecycle;
/* Only lifecycle state updates; never held while waiting or doing VM/GPU work. */
extern pthread_mutex_t hv_lifecycle_state_mu;
static inline bool hv_lifecycle_allowed(HvLifecycleGate *g) {
    return atomic_load(&g->active) && !atomic_load(&g->cancelled);
}
static inline void hv_lifecycle_set_active(HvLifecycleGate *g, int active) {
    atomic_store(&g->active, active != 0);
    pthread_cond_broadcast(&g->cv);
}
static inline void hv_lifecycle_cancel(HvLifecycleGate *g) {
    atomic_store(&g->cancelled,1);
    pthread_cond_broadcast(&g->cv);
}
static inline void hv_lifecycle_restart(HvLifecycleGate *g) {
    atomic_store(&g->cancelled,0); /* preserve the app's current active state */
}
static inline bool hv_lifecycle_wait_stoppable(HvLifecycleGate *g, const _Atomic int *stop) {
    pthread_mutex_lock(&g->mu);
    while (!atomic_load(&g->active) && !atomic_load(&g->cancelled) && !(stop && atomic_load(stop))) {
#if defined(__APPLE__)
        struct timespec interval={0,100000000};
        pthread_cond_timedwait_relative_np(&g->cv,&g->mu,&interval);
#else
        struct timespec until;clock_gettime(CLOCK_REALTIME,&until);
        until.tv_nsec+=100000000;
        if(until.tv_nsec>=1000000000){until.tv_sec++;until.tv_nsec-=1000000000;}
        pthread_cond_timedwait(&g->cv,&g->mu,&until);
#endif
    }
    bool allowed=hv_lifecycle_allowed(g) && !(stop && atomic_load(stop));
    pthread_mutex_unlock(&g->mu);
    return allowed;
}
static inline bool hv_lifecycle_wait(HvLifecycleGate *g) {
    return hv_lifecycle_wait_stoppable(g, NULL);
}
#endif
