// SPDX-License-Identifier: GPL-2.0-or-later
#include "fdt.h"

#include <stdlib.h>
#include <string.h>

#define FDT_MAGIC 0xd00dfeedu
#define FDT_BEGIN_NODE 1u
#define FDT_END_NODE 2u
#define FDT_PROP 3u
#define FDT_END 9u

static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24), p[1] = (uint8_t)(v >> 16), p[2] = (uint8_t)(v >> 8), p[3] = (uint8_t)v;
}

static int grow(uint8_t **buf, size_t *cap, size_t need) {
    if (need <= *cap) return 0;
    size_t n = *cap ? *cap : 4096;
    while (n < need) n *= 2;
    uint8_t *p = realloc(*buf, n);
    if (!p) return -1;
    *buf = p, *cap = n;
    return 0;
}

static void st_put(HvFdt *f, const void *data, size_t len) {
    size_t padded = (len + 3) & ~(size_t)3;
    if (f->failed || grow(&f->st, &f->st_cap, f->st_len + padded) != 0) {
        f->failed = 1;
        return;
    }
    memcpy(f->st + f->st_len, data, len);
    memset(f->st + f->st_len + len, 0, padded - len);
    f->st_len += padded;
}

static void st_word(HvFdt *f, uint32_t v) {
    uint8_t b[4];
    put_be32(b, v);
    st_put(f, b, 4);
}

/* Offset of name in the strings block, adding it the first time. */
static uint32_t string_off(HvFdt *f, const char *name) {
    size_t n = strlen(name) + 1;
    for (size_t at = 0; at < f->str_len; at += strlen((char *)f->str + at) + 1)
        if (!strcmp((char *)f->str + at, name)) return (uint32_t)at;
    if (f->failed || grow(&f->str, &f->str_cap, f->str_len + n) != 0) {
        f->failed = 1;
        return 0;
    }
    memcpy(f->str + f->str_len, name, n);
    f->str_len += n;
    return (uint32_t)(f->str_len - n);
}

void hv_fdt_init(HvFdt *f) {
    memset(f, 0, sizeof *f);
}

void hv_fdt_begin(HvFdt *f, const char *name) {
    st_word(f, FDT_BEGIN_NODE);
    st_put(f, name, strlen(name) + 1);
    f->depth++;
}

void hv_fdt_end(HvFdt *f) {
    st_word(f, FDT_END_NODE);
    f->depth--;
}

void hv_fdt_prop(HvFdt *f, const char *name, const void *data, size_t len) {
    st_word(f, FDT_PROP);
    st_word(f, (uint32_t)len);
    st_word(f, string_off(f, name));
    if (len) st_put(f, data, len);
}

void hv_fdt_str(HvFdt *f, const char *name, const char *value) {
    hv_fdt_prop(f, name, value, strlen(value) + 1);
}

void hv_fdt_strs(HvFdt *f, const char *name, const char *values, size_t len) {
    hv_fdt_prop(f, name, values, len);
}

void hv_fdt_u32(HvFdt *f, const char *name, uint32_t v) {
    hv_fdt_cells(f, name, &v, 1);
}

void hv_fdt_u64(HvFdt *f, const char *name, uint64_t v) {
    uint32_t c[2] = {(uint32_t)(v >> 32), (uint32_t)v};
    hv_fdt_cells(f, name, c, 2);
}

void hv_fdt_cells(HvFdt *f, const char *name, const uint32_t *cells, size_t n) {
    uint8_t *b = malloc(n * 4 + 1);
    if (!b) {
        f->failed = 1;
        return;
    }
    for (size_t i = 0; i < n; i++) put_be32(b + i * 4, cells[i]);
    hv_fdt_prop(f, name, b, n * 4);
    free(b);
}

void hv_fdt_empty(HvFdt *f, const char *name) {
    hv_fdt_prop(f, name, NULL, 0);
}

uint8_t *hv_fdt_finish(HvFdt *f, size_t *len) {
    st_word(f, FDT_END);
    uint8_t *out = NULL;
    if (!f->failed && f->depth == 0) {
        size_t hdr = 40, rsv = 16, off_st = hdr + rsv, off_str = off_st + f->st_len;
        size_t total = (off_str + f->str_len + 7) & ~(size_t)7;
        out = calloc(1, total);
        if (out) {
            put_be32(out + 0, FDT_MAGIC);
            put_be32(out + 4, (uint32_t)total);
            put_be32(out + 8, (uint32_t)off_st);
            put_be32(out + 12, (uint32_t)off_str);
            put_be32(out + 16, (uint32_t)hdr);   /* memory reservation map: one empty entry */
            put_be32(out + 20, 17);              /* version */
            put_be32(out + 24, 16);              /* last compatible version */
            put_be32(out + 28, 0);               /* boot CPU */
            put_be32(out + 32, (uint32_t)f->str_len);
            put_be32(out + 36, (uint32_t)f->st_len);
            memcpy(out + off_st, f->st, f->st_len);
            memcpy(out + off_str, f->str, f->str_len);
            *len = total;
        }
    }
    free(f->st);
    free(f->str);
    memset(f, 0, sizeof *f);
    return out;
}
