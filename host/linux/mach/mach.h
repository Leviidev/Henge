/* Linux host shim (tests only): the few Mach calls the engine makes, as failures or no-ops. */
#ifndef HENGE_LINUX_MACH_H
#define HENGE_LINUX_MACH_H
#include <stdint.h>
#include <stdlib.h>
#include "mach_time.h"
typedef int kern_return_t;
typedef unsigned mach_port_t;
typedef unsigned mach_msg_type_number_t;
typedef uintptr_t vm_address_t;
typedef int vm_prot_t;
typedef int *thread_info_t;
#define FALSE 0
#define TRUE 1
#define KERN_SUCCESS 0
#define KERN_FAILURE 5
#define MACH_PORT_NULL 0u
#define VM_FLAGS_ANYWHERE 1
#define VM_INHERIT_NONE 2
#define THREAD_BASIC_INFO 3
#define THREAD_BASIC_INFO_COUNT 10
#define TH_STATE_RUNNING 1
typedef struct { int seconds, microseconds; } time_value_t;
typedef struct {
    time_value_t user_time, system_time;
    int cpu_usage, policy, run_state, flags, suspend_count, sleep_time;
} thread_basic_info_data_t;
static inline mach_port_t mach_task_self(void) { return 1; }
static inline mach_port_t mach_thread_self(void) { return 0; }
static inline kern_return_t mach_port_deallocate(mach_port_t t, mach_port_t p) { (void)t, (void)p; return KERN_SUCCESS; }
static inline kern_return_t thread_info(mach_port_t t, int f, thread_info_t i, mach_msg_type_number_t *n) {
    (void)t, (void)f, (void)i, (void)n;
    return KERN_FAILURE;
}
static inline kern_return_t vm_remap(mach_port_t a, vm_address_t *b, uintptr_t c, uintptr_t d, int e, mach_port_t f,
                                     vm_address_t g, int h, vm_prot_t *i, vm_prot_t *j, int k) {
    (void)a, (void)b, (void)c, (void)d, (void)e, (void)f, (void)g, (void)h, (void)i, (void)j, (void)k;
    return KERN_FAILURE;
}
#endif
