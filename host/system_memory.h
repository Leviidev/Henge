#pragma once
#include <stdint.h>
#include <mach/mach.h>

/* Raw categories can overlap (notably purgeable/speculative/file-backed).
   No sum of these is a promise of allocatable physical RAM. */
typedef struct {
    uint64_t free, speculative, purgeable, compressed, wired;
    uint64_t active, inactive, external, internal;
} HvSystemMemory;
static inline int hv_system_memory_read(HvSystemMemory *out) {
    if(!out)return 0;
    *out=(HvSystemMemory){0};
    host_t host=mach_host_self();
    if(!MACH_PORT_VALID(host))return 0;
    vm_size_t page=0;
    vm_statistics64_data_t vm={0};
    mach_msg_type_number_t count=HOST_VM_INFO64_COUNT;
    int ok=host_page_size(host,&page)==KERN_SUCCESS && page &&
        host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&vm,&count)==KERN_SUCCESS &&
        count>=HOST_VM_INFO64_COUNT;
    mach_port_deallocate(mach_task_self(),host);
    if(!ok)return 0;
    *out=(HvSystemMemory){(uint64_t)vm.free_count*page,(uint64_t)vm.speculative_count*page,
        (uint64_t)vm.purgeable_count*page,(uint64_t)vm.compressor_page_count*page,
        (uint64_t)vm.wire_count*page,(uint64_t)vm.active_count*page,
        (uint64_t)vm.inactive_count*page,(uint64_t)vm.external_page_count*page,
        (uint64_t)vm.internal_page_count*page};
    return 1;
}
