#include "pvg_surface.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks, failures;
static struct {
    uint8_t bytes[0x20000];
    uint64_t limit, largest_read;
    unsigned reads;
} memory;

static void check(const char *what, int ok) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static const void *read_phys(void *opaque, uint64_t pa, uint64_t length) {
    (void)opaque;
    memory.reads++;
    if (length > memory.largest_read) memory.largest_read = length;
    if (pa > memory.limit || length > memory.limit - pa) return NULL;
    return memory.bytes + pa;
}

static void put(uint64_t pa, uint32_t value) { memcpy(memory.bytes + pa, &value, 4); }
static uint32_t pixel_page(uint64_t i) { return (uint32_t)(0x100000 + i * 4) | 1; }
static void reset(void) {
    memset(&memory, 0, sizeof memory);
    memory.limit = sizeof memory.bytes;
}

static void test_flat(void) {
    const uint64_t sizes[] = {1, 4095, 4096};
    reset();
    for (uint64_t i = 0; i < 4096; i++) put(0x4000 + i * 4, pixel_page(i));
    put(0x4000 + 17 * 4, 0); /* absent pixel pages must stay absent */
    for (unsigned k = 0; k < sizeof sizes / sizeof *sizes; k++) {
        uint64_t n = sizes[k];
        uint32_t *pages = hv_pvg_surface_pages(NULL, read_phys, 5, n);
        check("flat list through exactly 64 MiB", pages && !memcmp(pages, memory.bytes + 0x4000, (size_t)n * 4));
        free(pages);
    }
}

static void directory(void) {
    reset();
    /* Noncontiguous leaf lists; the directory's neighbouring page is poison.
       The old flat reader used these table/poison words as pixel addresses. */
    const uint64_t leaf[] = {0xc000, 0x14000, 0x1c000};
    memset(memory.bytes + 0x8000, 0xff, 0x4000);
    for (unsigned k = 0; k < 3; k++) {
        put(0x4000 + k * 4, (uint32_t)(leaf[k] >> 12) | 3);
        for (uint64_t i = 0; i < 4096; i++) put(leaf[k] + i * 4, pixel_page(k * 4096 + i));
    }
}

static void test_directory(void) {
    const uint64_t sizes[] = {4097, 5184, 5853, 8192, 8193, 9216};
    for (unsigned k = 0; k < sizeof sizes / sizeof *sizes; k++) {
        directory();
        uint64_t n = sizes[k];
        if (n == 9216) memory.limit = 0x1c000 + 1024 * 4; /* partial final leaf */
        uint32_t *pages = hv_pvg_surface_pages(NULL, read_phys, 5, n);
        int match = pages != NULL;
        for (uint64_t i = 0; pages && i < n; i++) if (pages[i] != pixel_page(i)) match = 0;
        check("large surface maps pixels, never directory or adjacent memory", match);
        check("no read exceeds a single table page", memory.largest_read <= 0x4000);
        free(pages);
    }
}

static void test_missing(void) {
    for (unsigned flag = 0; flag < 4; flag++) {
        directory();
        put(0x4004, 0x14 | flag);
        uint32_t *pages = hv_pvg_surface_pages(NULL, read_phys, 5, 9216);
        int match = pages != NULL;
        for (unsigned i = 0; pages && i < 9216; i++) {
            uint32_t want = i >= 4096 && i < 8192 && flag != 3 ? 0 : pixel_page(i);
            if (pages[i] != want) match = 0;
        }
        check("directory entries require both flags; neighbouring lists survive", match);
        free(pages);
    }
    directory();
    put(0x4004, 0x1003); /* well-formed pointer outside guest RAM */
    uint32_t *pages = hv_pvg_surface_pages(NULL, read_phys, 5, 9216);
    int match = pages != NULL;
    for (unsigned i = 0; pages && i < 9216; i++)
        if (pages[i] != (i >= 4096 && i < 8192 ? 0 : pixel_page(i))) match = 0;
    check("unreadable leaf is absent, never interpreted as pixels", match);
    free(pages);
    check("unreadable root", hv_pvg_surface_pages(NULL, read_phys, 0x1001, 9216) == NULL);
    check("unreadable flat list", hv_pvg_surface_pages(NULL, read_phys, 0x1001, 4096) == NULL);
    unsigned reads = memory.reads;
    check("absent root", hv_pvg_surface_pages(NULL, read_phys, 4, 9216) == NULL);
    check("zero pages", hv_pvg_surface_pages(NULL, read_phys, 5, 0) == NULL);
    check("more than two levels rejected", hv_pvg_surface_pages(NULL, read_phys, 5, 4096ull * 4096 + 1) == NULL);
    check("overflow-sized request rejected", hv_pvg_surface_pages(NULL, read_phys, 5, UINT64_MAX) == NULL);
    check("invalid requests never read guest memory", reads == memory.reads);
}

int main(void) {
    test_flat();
    test_directory();
    test_missing();
    printf("PVG surface pages: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
