#include "fastmem.h"
#include "machine.h"

#include <stdlib.h>

struct HvFastmem {
    HvFastmemEntry *read[2];
    /* Each occupied slot appears once, even after range drops or collisions.
       addend stays nonzero until full clear; tag=0 invalidates the mapping. */
    uint32_t *used;
    uint32_t nused;
    uint64_t fills, clears, drops, saturated;
};

void hv_fastmem_free(struct HvFastmem *fm) {
    if (!fm) return;
    free(fm->read[0]); free(fm->read[1]); free(fm->used); free(fm);
}

int hv_fastmem_attach(HvCpu *cpu, struct HvFastmem **owner, int enabled) {
    cpu->fm_read[0] = cpu->fm_read[1] = cpu->fm_base = 0;
    cpu->fm_attempts = cpu->fm_hits = 0;
    for (int i = 0; i < 4; i++) cpu->fm_misses[i] = 0;
    if (!enabled) { hv_fastmem_free(*owner); *owner = NULL; return 0; }
    if (!*owner) {
        struct HvFastmem *fm = calloc(1, sizeof *fm);
        if (!fm) return -1;
        fm->read[0] = calloc(HV_FASTMEM_PAGES, sizeof(HvFastmemEntry));
        fm->read[1] = calloc(HV_FASTMEM_PAGES, sizeof(HvFastmemEntry));
        fm->used = calloc(2 * HV_FASTMEM_PAGES, sizeof(uint32_t));
        if (!fm->read[0] || !fm->read[1] || !fm->used) { hv_fastmem_free(fm); return -1; }
        *owner = fm;
    }
    struct HvFastmem *fm = *owner;
    cpu->fm_read[0] = (uintptr_t)fm->read[0];
    cpu->fm_read[1] = (uintptr_t)fm->read[1];
    hv_fastmem_clear(cpu);
    return 0;
}

/* Only the owning CPU edits this table, under the walk_seq protocol shared
   with the ordinary TLB. The caller has checked granule, RAM and permissions.
   Keep scalar-only: the guest's SIMD registers are live on light refill. */
void hv_fastmem_fill(HvCpu *cpu, uint64_t va, int table, uint64_t addend) {
    if (!cpu->fm_read[0] || table < 1 || table > 2 || !addend || va >> 48 != 0xffff) return;
    struct HvFastmem *fm = cpu->pc_state->fastmem;
    uint32_t index = (va >> HV_TLB_PAGE_BITS) & (HV_FASTMEM_PAGES - 1);
    HvFastmemEntry *entry = &fm->read[table - 1][index];
    if (!entry->addend) {
        if (fm->nused == 2 * HV_FASTMEM_PAGES) {
            if (cpu->m->fastmem_diagnostics) __atomic_fetch_add(&fm->saturated, 1, __ATOMIC_RELAXED);
            return;
        }
        fm->used[fm->nused++] = (table - 1) * HV_FASTMEM_PAGES + index;
    }
    entry->addend = addend;
    entry->tag = (va & ~((1ull << HV_TLB_PAGE_BITS) - 1)) - HV_TLB_ADJ;
    if (cpu->m->fastmem_diagnostics) __atomic_fetch_add(&fm->fills, 1, __ATOMIC_RELAXED);
}

void hv_fastmem_clear(HvCpu *cpu) {
    if (!cpu->fm_read[0]) return;
    struct HvFastmem *fm = cpu->pc_state->fastmem;
    if (cpu->m->fastmem_diagnostics) __atomic_fetch_add(&fm->clears, 1, __ATOMIC_RELAXED);
    for (uint32_t k = 0; k < fm->nused; k++) {
        uint32_t code = fm->used[k];
        HvFastmemEntry *e = &fm->read[code / HV_FASTMEM_PAGES][code % HV_FASTMEM_PAGES];
        e->tag = e->addend = 0;
    }
    fm->nused = 0;
}

static int overlaps(uint64_t page, uint64_t start, uint64_t len) {
    return page <= start ? start - page < (1ull << HV_TLB_PAGE_BITS) : page - start < len;
}

void hv_fastmem_drop(HvCpu *cpu, uint64_t va, uint64_t len) {
    if (!cpu->fm_read[0] || !len || !((va >> 55) & 1)) return;
    struct HvFastmem *fm = cpu->pc_state->fastmem;
    uint64_t start = va & 0x00ffffffffffffffull;
    if (len >= HV_FASTMEM_SIZE) {
        // An overflow-safe range comparison across all populated windows.
        for (uint32_t k = 0; k < fm->nused; k++) {
            uint32_t code = fm->used[k];
            HvFastmemEntry *e = &fm->read[code / HV_FASTMEM_PAGES][code % HV_FASTMEM_PAGES];
            uint64_t page = (e->tag + HV_TLB_ADJ) & 0x00ffffffffffffffull;
            if (e->tag && overlaps(page, start, len)) e->tag = 0;
        }
    } else {
        uint64_t page = start & ~((1ull << HV_TLB_PAGE_BITS) - 1);
        uint64_t count = ((start - page) + len - 1) / (1ull << HV_TLB_PAGE_BITS) + 1;
        for (uint64_t k = 0; k < count; k++, page += 1ull << HV_TLB_PAGE_BITS) {
            uint32_t index = (page >> HV_TLB_PAGE_BITS) & (HV_FASTMEM_PAGES - 1);
            for (unsigned pan = 0; pan < 2; pan++) {
                HvFastmemEntry *e = &fm->read[pan][index];
                if (e->tag && (((e->tag + HV_TLB_ADJ) & 0x00ffffffffffffffull) == page)) e->tag = 0;
            }
        }
    }
    if (cpu->m->fastmem_diagnostics) __atomic_fetch_add(&fm->drops, 1, __ATOMIC_RELAXED);
}

void *hv_fastmem_read_ptr(HvCpu *cpu, uint64_t va, unsigned bytes, int table) {
    if (!cpu->fm_read[0] || table < 1 || table > 2 || !bytes || bytes > 8) return NULL;
    HvFastmemEntry *read = (HvFastmemEntry *)(uintptr_t)cpu->fm_read[table - 1];
    HvFastmemEntry e = read[(va >> HV_TLB_PAGE_BITS) & (HV_FASTMEM_PAGES - 1)];
    // A zero tag must not accept user VA zero; also reject the final 15 bytes.
    if (!e.tag || (va - e.tag) >> HV_TLB_PAGE_BITS) return NULL;
    return (void *)(uintptr_t)(va + e.addend);
}

int hv_fastmem_snapshot(HvCpu *cpu, HvFastmemSnapshot *out) {
    if (!cpu->fm_read[0]) return 0;
    struct HvFastmem *fm = cpu->pc_state->fastmem;
    out->base = out->reanchors = 0; // ABI-compatible snapshot: no anchored window.
    out->fills = __atomic_load_n(&fm->fills, __ATOMIC_RELAXED);
    out->clears = __atomic_load_n(&fm->clears, __ATOMIC_RELAXED);
    out->drops = __atomic_load_n(&fm->drops, __ATOMIC_RELAXED);
    out->saturated = __atomic_load_n(&fm->saturated, __ATOMIC_RELAXED);
    return 1;
}
