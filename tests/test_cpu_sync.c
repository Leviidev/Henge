#include "machine.h"
#include "fastmem.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <dlfcn.h>
static HvMachine m;
static HvCpu cpu[2];
static int action;
static uint64_t seq;
static int inject_notification;
/* Interpose only the executable's wait call; forward to the real kernel API.
   Inject a notification AFTER the production predicate check, BEFORE syscall
   entry. No timing sleep is needed to reproduce the lost-wakeup window. */
int __ulock_wait(uint32_t operation, void *addr, uint64_t value, uint32_t timeout_us) {
    static int (*kernel_wait)(uint32_t, void *, uint64_t, uint32_t);
    if (!kernel_wait) kernel_wait = (int (*)(uint32_t, void *, uint64_t, uint32_t))dlsym(RTLD_NEXT, "__ulock_wait");
    assert(kernel_wait);
    if (inject_notification) {
        int kind = inject_notification; inject_notification = 0;
        if (kind == 1) __atomic_store_n(&m.percpu[1].tlb_live, 0, __ATOMIC_SEQ_CST);
        else __atomic_store_n(&m.percpu[1].ack_seq, seq, __ATOMIC_RELEASE);
        hv_cpu_ack_wake(&cpu[1]);
    }
    return kernel_wait(operation, addr, value, timeout_us);
}

static void *finish_request(void *unused) {
    (void)unused;
    struct timespec delay = {0, 10000000}; nanosleep(&delay, NULL);
    if (action == 1) {
        __atomic_store_n(&m.percpu[1].tlb_live, 0, __ATOMIC_SEQ_CST);
        hv_cpu_ack_wake(&cpu[1]);
    } else if (action == 2) {
        /* Intentionally omit notification: bounded wait must recover. */
        __atomic_store_n(&m.percpu[1].ack_seq, seq, __ATOMIC_RELEASE);
    } else hv_cpu_process_requests(&cpu[1]);
    return NULL;
}
int main(void) {
    alarm(15);
    assert(!hv_machine_init(&m, 1 << 20));
    m.fastmem_enabled = 1;
    hv_cpu_reset_index(&cpu[0], &m, 0); hv_cpu_reset_index(&cpu[1], &m, 1);
    /* Already-completed requests must not publish a false park or wake our
       own waiters. Still process a pending invalidation on this CPU. */
    __atomic_store_n(&m.percpu[0].tlb_live,1,__ATOMIC_SEQ_CST);
    __atomic_store_n(&m.percpu[0].ack_waiters,1,__ATOMIC_SEQ_CST);
    seq=hv_cpu_post(&cpu[1],0);hv_cpu_process_requests(&cpu[1]);
    uint32_t event=m.percpu[0].ack_event;
    hv_cpu_sync(&cpu[0],&cpu[1],seq);
    assert(m.percpu[0].tlb_live && m.percpu[0].ack_event==event);
    uint64_t own_ready=hv_cpu_post(&cpu[0],HV_REQ_TLB_ALL);
    hv_cpu_sync(&cpu[0],&cpu[1],seq);
    assert(m.percpu[0].ack_seq==own_ready && m.percpu[0].ack_event==event+1 && m.percpu[0].tlb_live);
    __atomic_store_n(&m.percpu[0].ack_waiters,0,__ATOMIC_SEQ_CST);
    for (int enabled = 0; enabled <= 1; enabled++) {
        hv_knob[HV_K_SYNCWAIT] = enabled;
        for (int round = 0; round < 12; round++) {
            action = round % 3;
            __atomic_store_n(&m.percpu[0].tlb_live, 1, __ATOMIC_SEQ_CST);
            __atomic_store_n(&m.percpu[1].tlb_live, 1, __ATOMIC_SEQ_CST);
            const uint64_t regions[] = {0xfffffc0400010000ull, 0xfffffe0000020000ull};
            for (unsigned i = 0; i < 2; i++) for (unsigned r = 0; r < 2; r++) for (int pan = 1; pan <= 2; pan++) {
                hv_fastmem_fill(&cpu[i], regions[r], pan, 0x1000000 - regions[r]);
                assert(hv_fastmem_read_ptr(&cpu[i], regions[r], 8, pan));
            }
            seq = hv_cpu_post(&cpu[1], action == 0 ? HV_REQ_TLB_ALL : 0);
            uint64_t own = hv_cpu_post(&cpu[0], HV_REQ_TLB_ALL);
            pthread_t worker; assert(!pthread_create(&worker, NULL, finish_request, NULL));
            hv_cpu_sync(&cpu[0], &cpu[1], seq);
            assert(m.percpu[0].ack_seq == own && m.percpu[0].tlb_live);
            assert(!m.percpu[1].tlb_live || m.percpu[1].ack_seq >= seq);
            assert(!pthread_join(worker, NULL));
            for (unsigned r = 0; r < 2; r++) for (int pan = 1; pan <= 2; pan++) {
                assert(!hv_fastmem_read_ptr(&cpu[0], regions[r], 8, pan));
                if (action == 0) assert(!hv_fastmem_read_ptr(&cpu[1], regions[r], 8, pan));
            }
            assert(!m.percpu[1].ack_waiters);
            hv_cpu_process_requests(&cpu[1]);
        }
        if (!enabled) assert(!m.percpu[0].sync_sleeps);
    }
    assert(m.percpu[0].sync_sleeps && m.percpu[0].sync_timeouts);
    assert(!m.percpu[0].sync_errors);
    /* A peer parks or acks in the check-to-syscall window. The generation
       must prevent sleeping even though a parked peer's ack_seq stays put. */
    hv_knob[HV_K_SYNCWAIT] = 1;
    for (int kind = 1; kind <= 2; kind++) for (int i = 0; i < 32; i++) {
        __atomic_store_n(&m.percpu[0].tlb_live, 1, __ATOMIC_SEQ_CST);
        __atomic_store_n(&m.percpu[1].tlb_live, 1, __ATOMIC_SEQ_CST);
        seq = hv_cpu_post(&cpu[1], 0);
        uint64_t before = m.percpu[0].sync_timeouts;
        inject_notification = kind;
        hv_cpu_sync(&cpu[0], &cpu[1], seq);
        assert(!inject_notification && !m.percpu[1].ack_waiters);
        assert(m.percpu[0].sync_timeouts == before);
        hv_cpu_process_requests(&cpu[1]);
    }
    assert(!m.percpu[0].sync_errors);
    hv_machine_free(&m);
    puts("CPU sync: acknowledgement, parked target, missing notifications, 64 deterministic check-to-syscall races, own requests and multiwindow/PAN clears passed");
}
