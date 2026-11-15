#include "resource_policy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    HvResourceBudget b=hv_resource_budget(UINT64_MAX,0);assert(b.library_bytes==8ull<<20 && b.library_entries==32);
    b=hv_resource_budget(4ull<<30,0);assert(b.pressure==0);
    b=hv_resource_budget(400ull<<20,0);assert(b.pressure==1 && b.library_entries==8 && b.library_bytes==2ull<<20);
    b=hv_resource_budget(64ull<<20,0);assert(b.pressure==2 && !b.library_bytes && !b.library_entries);
    b=hv_resource_budget(4ull<<30,2);assert(b.pressure==2 && !b.library_bytes);
    b=hv_resource_budget(4ull<<30,1);assert(b.pressure==1);
    b=hv_resource_budget(4ull<<30,0);assert(b.pressure==0 && b.library_entries==32);
    b=hv_resource_budget(128ull<<20,0);assert(b.pressure==1);
    b=hv_resource_budget(512ull<<20,0);assert(b.pressure==0);
    b=hv_resource_budget_profile(4ull<<30,0,1);assert(b.library_entries==128 && b.library_bytes==16ull<<20);
    b=hv_resource_budget_profile(4ull<<30,0,0);assert(b.library_entries==32);
    b=hv_resource_budget_profile(UINT64_MAX,0,1);assert(b.library_entries==32);
    b=hv_resource_budget_profile((2ull<<30)-1,0,1);assert(b.library_entries==32);
    b=hv_resource_budget_profile(2ull<<30,0,1);assert(b.library_entries==128);
    b=hv_resource_budget_profile(4ull<<30,1,1);assert(b.library_entries==8 && b.library_bytes==2ull<<20);
    b=hv_resource_budget_profile(64ull<<20,0,1);assert(!b.library_entries);
    assert(hv_desktop_fx_limit(UINT64_MAX,0)==3);
    assert(hv_desktop_fx_limit(4ull<<30,0)==3);
    assert(hv_desktop_fx_limit(4ull<<30,1)==2);
    assert(hv_desktop_fx_limit(4ull<<30,2)==0);
    assert(hv_desktop_fx_limit((512ull<<20)-1,0)==0);
    assert(hv_desktop_fx_limit(512ull<<20,1)==2);
    puts("resource budget: dynamic headroom, pressure precedence, boundaries and recovery passed");
    puts("PASS MetalFX budget: nominal three leases, moderate two, critical/low allowance zero; warning is not confused with process headroom");
}
