#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "../devices/pvg_surface_copyback.h"
int main(void) {
    HvPvgSurfaceCopyback p;
    assert(hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 320, 258, 130, 1, &p));
    assert(p.guest_offset == 192 && p.shadow_offset == 64 && p.image == 41600 && p.active_row == 258);
    assert(hv_pvg_surface_copyback_plan(0, 41664, 49152, 64, 320, 258, 130, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(0, 41663, 49152, 64, 320, 258, 130, 1, &p));
    assert(hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 576, 129, 65, 4, &p));
    assert(p.active_row == 516);
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 65536, 64, 320, 258, 130, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(16384, 65536, 81920, 64, 320, 258, 130, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(0, 65536, 65536, UINT64_MAX, 320, 258, 130, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(0, UINT64_MAX, UINT64_MAX, 0, UINT64_MAX, 258, 130, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 320, 0, 130, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 320, 258, 0, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 320, 8193, 130, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 320, 258, 8193, 1, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 320, 258, 130, 0, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 320, 258, 130, 17, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 512, 258, 130, 2, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 65, 576, 129, 65, 4, &p));
    assert(!hv_pvg_surface_copyback_plan(129, 65536, 81920, 64, 576, 129, 65, 4, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 575, 129, 65, 4, &p));
    assert(!hv_pvg_surface_copyback_plan(128, 65536, 81920, 64, 576, 129, 65, 4, NULL));
    puts("surface copyback: padded/nonzero-offset boundaries and malformed layouts passed");
}
