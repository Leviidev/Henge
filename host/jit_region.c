#include "jit_region.h"
#include "cache_line_set.h"

#include <TargetConditionals.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

/* The split shape on a host that can make it itself: plain RW memory, an
   alias, and the original turned R-X. Works for macOS binaries without the
   hardened runtime; on iOS the executable half has to come from a debugger. */
static int open_split(HvJitRegion *region, size_t bytes) {
    void *rx = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (rx == MAP_FAILED) return -1;
    vm_address_t rw = 0;
    vm_prot_t cur, max;
    if (vm_remap(mach_task_self(), &rw, bytes, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)rx, FALSE, &cur, &max,
                 VM_INHERIT_NONE) != KERN_SUCCESS ||
        mprotect(rx, bytes, PROT_READ | PROT_EXEC) != 0) {
        munmap(rx, bytes);
        return -1;
    }
    if (hv_jit_region_attach(region, rx, (void *)rw, bytes) != 0) return -1;
    region->owned = 1;
    return 0;
}

int hv_jit_region_open(HvJitRegion *region, size_t bytes) {
    memset(region, 0, sizeof *region);
    if (getenv("HV_JIT_SPLIT")) return open_split(region, bytes);
#if TARGET_OS_OSX
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) return -1;
    region->base = p;
    region->capacity = bytes / sizeof(uint32_t);
    region->owned = 1;
    return 0;
#else
    return open_split(region, bytes); /* works only where nothing enforces code signing (tests on a jailbroken device) */
#endif
}

int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {
    memset(region, 0, sizeof *region);
    if (!rx || !rw || bytes < 4096) return -1;
    region->base = rx;
    region->rw_diff = (intptr_t)((uint8_t *)rw - (uint8_t *)rx);
    region->capacity = bytes / sizeof(uint32_t);
    return 0;
}

void hv_jit_region_close(HvJitRegion *region) {
    if (region->owned && region->base) {
        size_t bytes = region->capacity * sizeof(uint32_t);
        if (region->rw_diff) munmap((uint8_t *)region->base + region->rw_diff, bytes);
        munmap(region->base, bytes);
    }
    memset(region, 0, sizeof *region);
}

void hv_jit_write(HvJitRegion *region, uint32_t *start, const void *src, size_t bytes) {
    /* One instruction may be rewritten while other CPUs run it (chaining a branch).
       memcpy may copy a word in pieces, and a CPU fetching in between takes half of
       the old branch and half of the new one: a jump to nowhere. */
    if (bytes == 4) {
        uint32_t word;
        memcpy(&word, src, 4);
#if TARGET_OS_OSX
        if (!region->rw_diff) pthread_jit_write_protect_np(0);
#endif
        __atomic_store_n((uint32_t *)((uint8_t *)start + region->rw_diff), word, __ATOMIC_RELEASE);
        return;
    }
    if (region->rw_diff) {
        memcpy((uint8_t *)start + region->rw_diff, src, bytes);
        return;
    }
#if TARGET_OS_OSX
    pthread_jit_write_protect_np(0); /* MAP_JIT: writable on this thread only, until hv_jit_finish */
#endif
    memcpy(start, src, bytes);
}

void hv_jit_finish(HvJitRegion *region, uint32_t *start, size_t words) {
    (void)region;
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(1);
#endif
    if (start && words) sys_icache_invalidate(start, words * sizeof(uint32_t));
}

void hv_jit_finish_words(HvJitRegion *region, uint32_t *const *words, size_t n) {
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(1);
#endif
    size_t bytes=region->capacity<=SIZE_MAX/4?region->capacity*4:0;
    size_t bitmap_words=hv_cache_line_bitmap_words(bytes);
    // Large eviction batches can revisit a line many times in slot order.
    // At most8MiB scratch; allocation/range failures retain full publication.
    uint64_t *bitmap=n>=65536 && bitmap_words && bitmap_words<=(1u<<20) ? calloc(bitmap_words,sizeof *bitmap) : NULL;
    int grouped=bitmap && hv_cache_line_mark(bitmap,bitmap_words,(uintptr_t)region->base,bytes,words,n);
    __asm__ volatile("dsb ish" ::: "memory");
    size_t lines=0;
    if(grouped) {
        for(size_t i=0;i<bitmap_words;i++) {
            uint64_t pending=bitmap[i];
            while(pending) {
                unsigned bit=(unsigned)__builtin_ctzll(pending);pending&=pending-1;
                uintptr_t address=(uintptr_t)region->base+((i*64+bit)<<6);
                __asm__ volatile("ic ivau, %0" ::"r"(address):"memory");
                if(++lines%20==0)__asm__ volatile("dsb ish" ::: "memory");
            }
        }
    } else {
    uintptr_t last = 0;
    for (size_t k = 0; k < n; k++) {
        uintptr_t a = (uintptr_t)words[k] & ~(uintptr_t)63;
        if (a == last) continue;
        last = a;
        __asm__ volatile("ic ivau, %0" ::"r"(a) : "memory");
        lines++;
        if (k % 20 == 19) __asm__ volatile("dsb ish" ::: "memory"); /* as sys_icache_invalidate does, for the CPUs that need it */
    }
    }
    __asm__ volatile("dsb ish\n\tisb" ::: "memory");
    free(bitmap);
    __atomic_fetch_add(&region->publication_words,n,__ATOMIC_RELAXED);
    __atomic_fetch_add(&region->publication_lines,lines,__ATOMIC_RELAXED);
    __atomic_fetch_add(&region->publication_bitmap_batches,grouped,__ATOMIC_RELAXED);
}

void hv_jit_poison(HvJitRegion *region, uint32_t *start, size_t words) {
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(0); /* MAP_JIT: a direct write faults until this */
#endif
    memset((uint8_t *)start + region->rw_diff, 0, words * sizeof(uint32_t));
    hv_jit_finish(region, start, words);
}

/* As sys_icache_invalidate does it (libsystem_platform: DSB, IC IVAU per 64-byte line with a DSB after every 20 for
   the CPUs that need one, DSB, ISB), over both ranges. */
static void ic_lines(uint32_t *start, size_t words, int *n) {
    if (!start || !words) return;
    uintptr_t a = (uintptr_t)start & ~(uintptr_t)63, end = (uintptr_t)(start + words);
    for (; a < end; a += 64) {
        __asm__ volatile("ic ivau, %0" ::"r"(a) : "memory");
        if (++*n % 20 == 0) __asm__ volatile("dsb ish" ::: "memory");
    }
}

void hv_jit_finish2(HvJitRegion *region, uint32_t *a, size_t na, uint32_t *b, size_t nb) {
    (void)region;
#if TARGET_OS_OSX
    if (!region->rw_diff) pthread_jit_write_protect_np(1);
#endif
    int n = 0;
    __asm__ volatile("dsb ish" ::: "memory");
    ic_lines(a, na, &n);
    ic_lines(b, nb, &n);
    __asm__ volatile("dsb ish\n\tisb" ::: "memory");
}

static pthread_once_t branch_policy_once = PTHREAD_ONCE_INIT;
static void branch_policy(void) {
    const char *p = getenv("HV_JIT_RELAXED_BRANCH");
    if (p && !strcmp(p, "1"))
        fprintf(stderr, "henge: relaxed branch publication unavailable: native correctness check failed; using full cache synchronization\n");
}
void hv_jit_finish_branch(HvJitRegion *region, uint32_t *word) {
    pthread_once(&branch_policy_once, branch_policy);
    /* An ISB alone did not guarantee visibility of a just-patched branch on
       the native cloud Mac. Preserve publication completion for every mode. */
    hv_jit_finish(region, word, 1);
}

static size_t region_cap(const HvJitRegion *region) {
    size_t cap=__atomic_load_n(&region->capacity,__ATOMIC_RELAXED);
    size_t limit=__atomic_load_n(&region->limit,__ATOMIC_RELAXED);
    return limit && limit<cap ? limit : cap;
}

/* Any thread: an even number of words (blocks stay 8-byte aligned), taken atomically. */
uint32_t *hv_jit_reserve(HvJitRegion *region, size_t words) {
    if (words == SIZE_MAX) return NULL;
    words = (words + 1) & ~(size_t)1;
    if (!words) return region->base + __atomic_load_n(&region->used,__ATOMIC_RELAXED);
    size_t seg = region->seg_words;
    if (!seg) {
        size_t cap = region->limit && region->limit < region->capacity ? region->limit : region->capacity;
        size_t at = __atomic_load_n(&region->used, __ATOMIC_RELAXED);
        for (;;) {
            if (at > cap || words > cap - at) return NULL;
            size_t next = at + words;
            if (__atomic_compare_exchange_n(&region->used, &at, next, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) return region->base + at;
        }
    }
    if (words > seg) {
        __atomic_store_n(&region->too_big, 1, __ATOMIC_RELAXED);
        return NULL;
    }
    /* Within one segment, so taking a segment back never splits a reservation (a CPU's chunk). */
    size_t at = __atomic_load_n(&region->used, __ATOMIC_RELAXED), to;
    do {
        to = at;
        if (to / seg != (to + words - 1) / seg) to = (to / seg + 1) * seg;
        if (to + words > region->end) return NULL; /* full: hv_jit_evict_next makes room */
    } while (!__atomic_compare_exchange_n(&region->used, &at, to + words, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED));
    return region->base + to;
}

void hv_jit_reset(HvJitRegion *region) {
    __atomic_store_n(&region->used,0,__ATOMIC_RELAXED);
    __atomic_store_n(&region->wrapped,0,__ATOMIC_RELAXED);
    region->too_big = 0;
    region->retention_clock=region->nseg;__atomic_store_n(&region->retention_nonfifo,0,__ATOMIC_RELAXED);
    for(unsigned k=0;k<HV_JIT_MAX_SEGS;k++){region->segment_birth[k]=k+1;region->segment_heat[k]=0;}
    region->end = (size_t)region->seg_words * region->nseg;
    for (uint32_t k = 0; k < HV_JIT_MAX_SEGS; k++) region->seg_epoch[k]++;
}

void hv_jit_ring(HvJitRegion *region, uint32_t nseg) {
    if (nseg > HV_JIT_MAX_SEGS) nseg = HV_JIT_MAX_SEGS;
    size_t seg = nseg >= 2 ? (region_cap(region) / nseg) & ~(size_t)1 : 0;
    if (seg < 2048) seg = 0, nseg = 0; /* under 8 KB a segment holds too few blocks to be worth keeping the rest */
    __atomic_store_n(&region->seg_words,seg,__ATOMIC_RELAXED);
    __atomic_store_n(&region->nseg,nseg,__ATOMIC_RELAXED);
    hv_jit_reset(region);
}

uint32_t hv_jit_evict_next(HvJitRegion *region) {
    size_t seg = region->seg_words, total = seg * region->nseg;
    uint32_t k;
    if (region->end >= total) { /* the last segment is in use: round to the first */
        k = 0;
        __atomic_store_n(&region->used,0,__ATOMIC_RELAXED);
        __atomic_store_n(&region->wrapped,1,__ATOMIC_RELAXED);
    } else {
        k = (uint32_t)(region->end / seg);
        __atomic_store_n(&region->used,region->end,__ATOMIC_RELAXED);
    }
    region->end = (k + 1) * seg;
    region->seg_epoch[k]++;
    return k;
}

/* Every CPU parked. Recent execution is sampled at existing dispatcher/helper
   boundaries. No code moves; only the chosen segment's reservation epoch does. */
uint32_t hv_jit_evict_policy(HvJitRegion *region,uint64_t seen,int adaptive) {
    if(!adaptive||region->nseg<4)return hv_jit_evict_next(region);
    unsigned chosen=0;
    for(unsigned k=0;k<region->nseg;k++) {
        region->segment_heat[k]=(uint8_t)((region->segment_heat[k]>>1)+((seen>>k&1)?128:0));
        if(region->segment_heat[k]<region->segment_heat[chosen] ||
           (region->segment_heat[k]==region->segment_heat[chosen] && region->segment_birth[k]<region->segment_birth[chosen]))chosen=k;
    }
    unsigned fifo=region->end>=region->seg_words*region->nseg?0:(unsigned)(region->end/region->seg_words);
    if(chosen!=fifo)__atomic_fetch_add(&region->retention_nonfifo,1,__ATOMIC_RELAXED);
    region->segment_birth[chosen]=++region->retention_clock;
    __atomic_store_n(&region->used,(size_t)chosen*region->seg_words,__ATOMIC_RELAXED);
    __atomic_store_n(&region->wrapped,1,__ATOMIC_RELAXED);
    region->end=(size_t)(chosen+1)*region->seg_words;
    region->seg_epoch[chosen]++;
    return chosen;
}

size_t hv_jit_extent(const HvJitRegion *region) {
    /* Resource captures run outside the translation lock. Emitters update used
       concurrently; ring/reset publication must use the same atomic accesses.
       A capture across a layout change is approximate but always cap-bounded. */
    size_t cap=region_cap(region),used=__atomic_load_n(&region->used,__ATOMIC_RELAXED);
    if(__atomic_load_n(&region->wrapped,__ATOMIC_RELAXED)) {
        size_t seg=__atomic_load_n(&region->seg_words,__ATOMIC_RELAXED);
        uint32_t n=__atomic_load_n(&region->nseg,__ATOMIC_RELAXED);
        return n && seg>cap/n ? cap : seg*n;
    }
    return used<cap ? used : cap;
}
