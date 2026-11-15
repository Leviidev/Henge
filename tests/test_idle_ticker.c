#define _POSIX_C_SOURCE 200809L
#include "idle_ticker.h"
#include <assert.h>
#include <stdio.h>
#include <time.h>

static HvIdleTicker ticker = HV_IDLE_TICKER_INITIALIZER;
static _Atomic int active, checks, resumed;
static int is_active(void *unused) { (void)unused; atomic_fetch_add(&checks, 1); return atomic_load_explicit(&active, memory_order_seq_cst); }
static void *worker(void *opaque) {
    uint64_t token = (uintptr_t)opaque;
    while (hv_idle_ticker_wait(&ticker, token, is_active, NULL)) {
        atomic_store_explicit(&active, 0, memory_order_seq_cst);
        atomic_fetch_add(&resumed, 1);
    }
    return NULL;
}
static void pause_ms(long ms) { struct timespec t = {ms/1000, ms%1000*1000000}; nanosleep(&t, NULL); }
static void await_value(_Atomic int *p, int expected) {
    for (int i=0; i<2000 && atomic_load(p)!=expected; i++) pause_ms(1);
    assert(atomic_load(p)==expected);
}
static void await_waiter(void) {
    for (int i=0; i<2000 && !atomic_load(&ticker.waiters); i++) pause_ms(1);
    assert(atomic_load(&ticker.waiters));
    /* Synchronize through the wait mutex: seeing the waiter count alone could
       be between arming it and checking the condition. */
    pthread_mutex_lock(&ticker.mu); pthread_mutex_unlock(&ticker.mu);
}
int main(void) {
    uint64_t token = hv_idle_ticker_advance(&ticker);
    pthread_t t;
    assert(pthread_create(&t, NULL, worker, (void *)(uintptr_t)token)==0);
    await_waiter();
    int before = atomic_load(&checks);
    pause_ms(100);
    assert(atomic_load(&checks)==before); /* no periodic CPU-state polling */
    for (int i=1; i<=1000; i++) {
        atomic_store_explicit(&active, 1, memory_order_seq_cst);
        hv_idle_ticker_notify(&ticker);
        await_value(&resumed, i);
        /* Alternate an armed wait and a wake racing the next arm. */
        if (i%2) await_waiter();
    }
    await_waiter();
    hv_idle_ticker_advance(&ticker); /* cancellation must wake a quiet worker */
    pthread_join(t, NULL);
    assert(atomic_load(&ticker.waiters)==0);
    /* An old cancelled generation cannot return ready after a new start. */
    uint64_t newer = hv_idle_ticker_advance(&ticker);
    atomic_store(&active, 1);
    assert(!hv_idle_ticker_wait(&ticker, token, is_active, NULL));
    assert(hv_idle_ticker_wait(&ticker, newer, is_active, NULL));
    printf("idle ticker: no periodic checks at idle; 1000 activation races, cancellation and stale-generation rejection passed (%llu sleeps)\n", (unsigned long long)atomic_load(&ticker.sleeps));
}
