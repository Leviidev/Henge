#ifndef HENGE_RECLAIM_PAGES_H
#define HENGE_RECLAIM_PAGES_H
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
#include <unistd.h>

/* Only dead payload after a global quiescent reset. Keep partial allocation
   pages untouched: they can share allocator metadata or another allocation.
   Never use this on executable aliases or live translation structures. */
static inline size_t hv_reclaim_retired_pages(void *memory, size_t bytes) {
#if defined(MADV_FREE)
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    uintptr_t first = (uintptr_t)memory;
    if (!memory || !page || page == (size_t)-1 || bytes > UINTPTR_MAX - first) return 0;
    uintptr_t end = first + bytes;
    size_t prefix = (page - first % page) % page;
    if (prefix >= bytes) return 0;
    uintptr_t start = first + prefix;
    end -= end % page;
    if (end <= start) return 0;
    return madvise((void *)start, end - start, MADV_FREE) ? 0 : end - start;
#else
    (void)memory; (void)bytes;
    return 0;
#endif
}
#endif
