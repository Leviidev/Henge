// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef HENGEVM_FDT_H
#define HENGEVM_FDT_H

#include <stddef.h>
#include <stdint.h>

/* A small flattened device tree writer (the DTB format Linux takes in x0 at
   boot): nodes and properties appended in order, then finished into one blob. */
typedef struct HvFdt {
    uint8_t *st, *str; /* structure and strings blocks */
    size_t st_len, st_cap, str_len, str_cap;
    int depth, failed;
} HvFdt;

void hv_fdt_init(HvFdt *f);
void hv_fdt_begin(HvFdt *f, const char *name);
void hv_fdt_end(HvFdt *f);
void hv_fdt_prop(HvFdt *f, const char *name, const void *data, size_t len);
void hv_fdt_str(HvFdt *f, const char *name, const char *value);
/* Several strings in one property ("a\0b\0"): pass the total length, final NUL included. */
void hv_fdt_strs(HvFdt *f, const char *name, const char *values, size_t len);
void hv_fdt_u32(HvFdt *f, const char *name, uint32_t v);
void hv_fdt_u64(HvFdt *f, const char *name, uint64_t v);
void hv_fdt_cells(HvFdt *f, const char *name, const uint32_t *cells, size_t n);
void hv_fdt_empty(HvFdt *f, const char *name);
/* The blob (malloc'd, *len set), or NULL; frees the builder either way. */
uint8_t *hv_fdt_finish(HvFdt *f, size_t *len);

#endif
