/* Linux host shim (tests only): mach_absolute_time as a 24 MHz counter, like Apple silicon's. */
#ifndef HENGE_LINUX_MACH_TIME_H
#define HENGE_LINUX_MACH_TIME_H
#include <stdint.h>
#include <time.h>
#include <stdlib.h>
/* HV_CLOCK_DIV=n runs the guest's clock n times slower than real time: under
   qemu-aarch64 the guest is so slow that a 250 Hz kernel spends all its time
   in the timer tick otherwise. */
static inline uint64_t mach_absolute_time(void) {
    static uint64_t div;
    if (!div) {
        const char *d = getenv("HV_CLOCK_DIV");
        div = d && atoi(d) > 1 ? (uint64_t)atoi(d) : 1;
    }
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 24000000u + (uint64_t)ts.tv_nsec * 3u / 125u) / div;
}
typedef struct { uint32_t numer, denom; } mach_timebase_info_data_t;
static inline int mach_timebase_info(mach_timebase_info_data_t *t) { t->numer = 125; t->denom = 3; return 0; }
#endif
