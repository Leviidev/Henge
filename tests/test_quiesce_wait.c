#define _DARWIN_C_SOURCE 1
#include "quiesce_wait.h"
#include <assert.h>
#include <sched.h>
#include <stdio.h>
#include <unistd.h>
static HvQuiesceWait q;
static _Atomic unsigned busy, ready, pending;
static int predicate(void *unused) {(void)unused;return atomic_load(&busy) && !atomic_load(&pending);}
static void *finish(void *mode) {
    while(!atomic_load(&ready))sched_yield();
    struct timespec d={0,1000000};nanosleep(&d,NULL);
    if((uintptr_t)mode==1)atomic_store(&pending,1);
    else atomic_store(&busy,0);
    if((uintptr_t)mode!=2)hv_quiesce_notify(&q);
    return NULL;
}
int main(void) {
    alarm(20);assert(!hv_quiesce_init(&q));
    for(unsigned i=0;i<300;i++) {
        atomic_store(&ready,0);atomic_store(&pending,0);atomic_store(&busy,1);
        pthread_t t;assert(!pthread_create(&t,NULL,finish,(void *)(uintptr_t)(i%3)));
        atomic_store(&ready,1);
        while(predicate(NULL)){int rc=hv_quiesce_wait(&q,predicate,NULL);assert(!rc || rc==ETIMEDOUT);}
        assert(!pthread_join(t,NULL));assert(!atomic_load(&q.waiters));
    }
    /* Publication before the waiter arms must never sleep or lose a wake. */
    atomic_store(&busy,0);unsigned long long before=atomic_load(&q.waits);
    for(unsigned i=0;i<10000;i++)assert(!hv_quiesce_wait(&q,predicate,NULL));
    assert(atomic_load(&q.waits)==before && !atomic_load(&q.errors));
    /* Same 200x1ms wait-only workload, process CPU rather than made-up watts. */
    double cpu[2];
    for(unsigned mode=0;mode<2;mode++) {
        clock_t start=clock();
        for(unsigned i=0;i<200;i++) {
            atomic_store(&ready,0);atomic_store(&pending,0);atomic_store(&busy,1);
            pthread_t t;assert(!pthread_create(&t,NULL,finish,NULL));atomic_store(&ready,1);
            while(predicate(NULL)){
                if(mode)hv_quiesce_wait(&q,predicate,NULL);else sched_yield();
            }
            assert(!pthread_join(t,NULL));
        }
        cpu[mode]=(double)(clock()-start)/CLOCKS_PER_SEC;
    }
    printf("PASS quiesce: 300 park/request/missed-notification races, 10000 pre-published checks, no errors; wait-only process CPU legacy=%.6fs event=%.6fs (synthetic, not gaming/power/FPS)\n",cpu[0],cpu[1]);
    hv_quiesce_destroy(&q);
}
