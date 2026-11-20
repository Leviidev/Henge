// SPDX-License-Identifier: GPL-2.0-or-later
/* Linux host shim (tests only): Apple's __ulock_wait/__ulock_wake on futexes. */
#include <limits.h>
#include <linux/futex.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

int __ulock_wait(uint32_t operation, void *addr, uint64_t value, uint32_t timeout_us) {
    (void)operation;
    struct timespec ts = {.tv_sec = timeout_us / 1000000u, .tv_nsec = (long)(timeout_us % 1000000u) * 1000};
    return (int)syscall(SYS_futex, addr, FUTEX_WAIT_PRIVATE, (uint32_t)value, timeout_us ? &ts : NULL, NULL, 0);
}

int __ulock_wake(uint32_t operation, void *addr, uint64_t wake_value) {
    (void)wake_value;
    int all = (operation & 0x100) != 0; /* ULF_WAKE_ALL */
    return (int)syscall(SYS_futex, addr, FUTEX_WAKE_PRIVATE, all ? INT_MAX : 1, NULL, NULL, 0);
}
