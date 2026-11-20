/* Force-included in the Linux host build (tests only; make linux-test). */
#ifndef HENGE_LINUX_COMPAT_H
#define HENGE_LINUX_COMPAT_H
#define _GNU_SOURCE 1
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#ifndef MAP_JIT
#define MAP_JIT 0
#endif
#define pthread_jit_write_protect_np(x) ((void)(x))
#define F_NOCACHE 48
#define F_BARRIERFSYNC 85
#include <stdlib.h> /* glibc 2.36+ has arc4random */
static inline int pthread_cond_timedwait_relative_np(pthread_cond_t *cv, pthread_mutex_t *mu, const struct timespec *rel) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += rel->tv_sec;
    ts.tv_nsec += rel->tv_nsec;
    if (ts.tv_nsec >= 1000000000) ts.tv_sec++, ts.tv_nsec -= 1000000000;
    return pthread_cond_timedwait(cv, mu, &ts);
}
#endif
