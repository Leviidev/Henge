/* The JIT region tests/test_project.swift runs in. */
void henge_ios_release_high_room(void) {}
#include <stdatomic.h>
#include <stdlib.h>

#include "henge-ios-jit.h"
#include "jit_region.h"
#include "test_project.h"

static HvJitRegion jit;
static HengeDualMapping mapping;
_Atomic int henge_tl_ran;
int henge_vm_state(void) { return 0; }
HengeDualMapping *henge_ios_jit_get_mapping(void) { return &mapping; }
int test_map(int megabytes) {
    setenv("HV_JIT_SPLIT", "1", 1); /* the iOS shape */
    if (hv_jit_region_open(&jit, (size_t)megabytes << 20)) return -1;
    mapping = (HengeDualMapping){.rx_addr = (uint8_t *)jit.base, .rw_addr = (uint8_t *)jit.base + jit.rw_diff, .size = jit.capacity * 4};
    return 0;
}
