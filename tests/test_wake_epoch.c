#include "wake_epoch.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

static HvWakeEpoch epoch;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int sleeping, release_worker, kicks;
static void *worker(void *arg) {
    uint64_t token = (uintptr_t)arg;
    assert(hv_wake_current(&epoch, token));
    pthread_mutex_lock(&mu);
    sleeping = 1; pthread_cond_signal(&cv);
    while (!release_worker) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
    if (hv_wake_current(&epoch, token)) kicks++;
    return NULL;
}
int main(void) {
    uint64_t first = hv_wake_advance(&epoch);
    pthread_t t;
    assert(pthread_create(&t, NULL, worker, (void *)(uintptr_t)first) == 0);
    pthread_mutex_lock(&mu);
    while (!sleeping) pthread_cond_wait(&cv, &mu);
    hv_wake_advance(&epoch); /* stop while worker sleeps */
    uint64_t next = hv_wake_advance(&epoch); /* a new start must not revive it */
    assert(hv_wake_current(&epoch, next) && !hv_wake_current(&epoch, first));
    release_worker = 1; pthread_cond_signal(&cv);
    pthread_mutex_unlock(&mu);
    pthread_join(t, NULL);
    assert(kicks == 0);
    hv_wake_advance(&epoch);
    assert(!hv_wake_current(&epoch, next));
    puts("wake ticker: stop during sleep and restart cannot revive stale worker");
}
