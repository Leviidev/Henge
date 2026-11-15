#define _DEFAULT_SOURCE
#include "mmu.h"
#include "cursor_damage.h"
#include "reclaim_pages.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
int hv_tlb_tmajor;
int main(void) {
    HvCpu *cpu = calloc(1, sizeof *cpu);
    uint8_t *ram = calloc(1, 32768);
    assert(cpu && ram);
    memset(cpu->tlb, 0x80, sizeof cpu->tlb);
    uint64_t va = 0x10000;
    HvTlbEntry *e = hv_tlb_ent(cpu, (va >> 14) & (HV_TLB_SIZE - 1), 0);
    e->read_tag = va - HV_TLB_ADJ; e->addend = (uintptr_t)ram - va;
    assert(hv_tlb_read_span(cpu, va + 16376, 8, 0) == ram + 16376);
    assert(!hv_tlb_read_span(cpu, va + 16376, 16, 0));
    assert(!hv_tlb_read_span(cpu, va, 0, 0));
    assert(!hv_tlb_read_span(cpu, va, 8, 1));
    cpu->pstate_extra = HV_PSTATE_PAN;
    HvTlbEntry *pan = hv_tlb_ent(cpu, (va >> 14) & (HV_TLB_SIZE - 1), 2);
    pan->read_tag = va - HV_TLB_ADJ; pan->addend = (uintptr_t)ram - va;
    assert(hv_tlb_read_span(cpu, va, 8, 1) == ram);
    cpu->pstate_extra = 0;
    assert(!hv_tlb_read_span(cpu, va, 8, 1));
    e->read_tag = HV_TLB_INVALID;
    assert(!hv_tlb_read_span(cpu, va, 8, 0));
    free(cpu); free(ram);
    HvCursorDamage d = {0};
    HvCursorDamageKey k = {.layer=1,.glyph=1,.position=100,.visible=1,.settings=3};
    assert(hv_cursor_damage_changed(&d,k)); assert(!hv_cursor_damage_changed(&d,k));
    k.position++; assert(hv_cursor_damage_changed(&d,k));
    k.glyph++; assert(hv_cursor_damage_changed(&d,k));
    k.settings++; assert(hv_cursor_damage_changed(&d,k));
    k.visible=0; assert(hv_cursor_damage_changed(&d,k));
    k.position++; k.glyph++; assert(!hv_cursor_damage_changed(&d,k));
    k.layer++; assert(hv_cursor_damage_changed(&d,k));
    size_t page=(size_t)sysconf(_SC_PAGESIZE);
    assert(!hv_reclaim_retired_pages((void *)UINTPTR_MAX,0));
    assert(!hv_reclaim_retired_pages((void *)UINTPTR_MAX,1));
    void *p=NULL; assert(!posix_memalign(&p,page,page*4)); memset(p,0x5a,page*4);
    size_t advised=hv_reclaim_retired_pages((uint8_t *)p+1,page*4-2);
    assert(!advised || advised == page*2);
    assert(((uint8_t *)p)[0]==0x5a && ((uint8_t *)p)[page*4-1]==0x5a);
    memset(p,0xa5,page*4); assert(((uint8_t *)p)[page*2]==0xa5); free(p);
    puts("PASS TLB span permissions/bounds, exact cursor damage, retired-page boundaries and reuse");
}
