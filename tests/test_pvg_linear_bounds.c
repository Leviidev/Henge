#include "pvg_linear_bounds.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(hv_pvg_linear_bounds(72,72,4,11952,1440,114480,16));
    assert(!hv_pvg_linear_bounds(72,72,4,11952,1440,114479,16));
    assert(!hv_pvg_linear_bounds(72,72,4,11953,1440,114688,16));
    assert(!hv_pvg_linear_bounds(72,72,4,11952,1439,114688,16));
    assert(!hv_pvg_linear_bounds(72,0,4,0,288,114688,16));
    assert(!hv_pvg_linear_bounds(UINT64_MAX,2,4,0,288,UINT64_MAX,16));
    assert(!hv_pvg_linear_bounds(72,UINT64_MAX,4,0,288,UINT64_MAX,16));
    assert(!hv_pvg_linear_bounds(1,2,4,UINT64_MAX,4,UINT64_MAX,0));
    assert(hv_pvg_linear_bounds(1,1,4,0,4096,4,0));
    puts("linear texture bounds: final visible row, exact/short lengths, alignment, zero size and overflow passed");
}
