#include "../devices/pvg_store_action.h"
#include <assert.h>
int main(void) {
    HvStoreAction a;
    const uint32_t color[] = {1, 7};
    assert(hv_pvg_decode_store_action(102, color, sizeof color, &a));
    assert(a.value == 1 && a.index == 7);
    const uint32_t options[] = {1, 0, 6};
    assert(hv_pvg_decode_store_action(103, options, sizeof options, &a));
    assert(a.value == 1 && a.index == 6);
    const uint64_t store = 1, option = 0;
    assert(hv_pvg_decode_store_action(105, &store, 8, &a) && a.value == 1);
    assert(hv_pvg_decode_store_action(120, &store, 8, &a) && a.value == 1);
    assert(hv_pvg_decode_store_action(106, &option, 8, &a) && a.value == 0);
    assert(hv_pvg_decode_store_action(121, &option, 8, &a) && a.value == 0);
    for (unsigned n = 0; n < 8; n++) assert(!hv_pvg_decode_store_action(102, color, n, &a));
    for (unsigned n = 0; n < 12; n++) assert(!hv_pvg_decode_store_action(103, options, n, &a));
    const uint64_t wide = UINT64_C(0x100000001), unknown = 4;
    assert(!hv_pvg_decode_store_action(105, &wide, 8, &a));
    assert(!hv_pvg_decode_store_action(120, &unknown, 8, &a));
    assert(!hv_pvg_decode_store_action(145, &store, 8, &a));
    const uint32_t bad_index[] = {1, 8};
    assert(!hv_pvg_decode_store_action(102, bad_index, 8, &a));
    return 0;
}
