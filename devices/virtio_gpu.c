// SPDX-License-Identifier: GPL-2.0-or-later
/* virtio-gpu (virtio 1.x, 5.7) for the Linux machine: see virtio_gpu.h. */
#include "virtio_gpu.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CTRLQ 0
#define CURSORQ 1

#define F_VIRGL (1ull << 0)

/* Commands. */
#define CMD_GET_DISPLAY_INFO 0x0100
#define CMD_RESOURCE_CREATE_2D 0x0101
#define CMD_RESOURCE_UNREF 0x0102
#define CMD_SET_SCANOUT 0x0103
#define CMD_RESOURCE_FLUSH 0x0104
#define CMD_TRANSFER_TO_HOST_2D 0x0105
#define CMD_RESOURCE_ATTACH_BACKING 0x0106
#define CMD_RESOURCE_DETACH_BACKING 0x0107
#define CMD_GET_CAPSET_INFO 0x0108
#define CMD_GET_CAPSET 0x0109
#define CMD_CTX_CREATE 0x0200
#define CMD_CTX_DESTROY 0x0201
#define CMD_CTX_ATTACH_RESOURCE 0x0202
#define CMD_CTX_DETACH_RESOURCE 0x0203
#define CMD_RESOURCE_CREATE_3D 0x0204
#define CMD_TRANSFER_TO_HOST_3D 0x0205
#define CMD_TRANSFER_FROM_HOST_3D 0x0206
#define CMD_SUBMIT_3D 0x0207
#define CMD_UPDATE_CURSOR 0x0300
#define CMD_MOVE_CURSOR 0x0301

#define RESP_OK_NODATA 0x1100
#define RESP_OK_DISPLAY_INFO 0x1101
#define RESP_OK_CAPSET_INFO 0x1102
#define RESP_OK_CAPSET 0x1103
#define RESP_ERR_UNSPEC 0x1200
#define RESP_ERR_OUT_OF_MEMORY 0x1201
#define RESP_ERR_INVALID_SCANOUT_ID 0x1202
#define RESP_ERR_INVALID_RESOURCE_ID 0x1203
#define RESP_ERR_INVALID_CONTEXT_ID 0x1204
#define RESP_ERR_INVALID_PARAMETER 0x1205

#define FLAG_FENCE 1u
#define EVENT_DISPLAY 1u

#define HDR 24 /* type, flags, fence_id (8), ctx_id, ring_idx, padding[3] */
#define MAX_RES_BYTES (512ull << 20) /* all 2D resources together, in host memory */
#define BUCKETS 256
#define MAX_PENDING 1024

typedef struct Res {
    uint32_t id, format, width, height;
    int is3d;
    uint8_t *data; /* 2D: the resource's pixels, width * 4 per row, in its own format */
    void **iov_base;
    uint32_t *iov_len;
    uint64_t *iov_at; /* where each piece starts in the backing */
    uint32_t niov;
    struct Res *next;
} Res;

typedef struct Pending {
    HvVirtqElem e;
    uint8_t resp[HDR];
    uint64_t fence;
} Pending;

struct HvVirtioGpu {
    HvVirtio vio;
    Res *res[BUCKETS];
    uint64_t res_bytes;
    uint32_t pref_w, pref_h;
    _Atomic uint64_t want_size; /* w << 32 | h from set_size, applied by poll */
    /* The scanout: which resource, and where in it. */
    uint32_t scanout_res, sx, sy;
    /* The screen, for other threads. */
    pthread_mutex_t mu;
    HvVgpuScreen screen;
    uint8_t cursor[64 * 64 * 4];
    int cursor_on;
    uint32_t hot_x, hot_y;
    int32_t cur_x, cur_y;
    _Atomic uint32_t host_at; /* where the host draws the pointer (x | y << 16, screen pixels), or ~0: the guest's place */
    HvVgpuPresenter pres; /* under mu */
    int has_pres;
    uint64_t readback_ns; /* when the screen's pixels were last read back while a presenter shows textures */
    /* 3D */
    HvVgpu3d gl;
    int has_gl;
    Pending *pending;
    uint32_t npending;
    _Atomic uint64_t fence_done;
    uint8_t *cmd;
    uint32_t cmd_cap;
    int log;
    _Atomic uint64_t submits, submit_bytes; /* 3D command buffers so far, and their bytes */
};

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t rd64(const uint8_t *p) { return rd32(p) | (uint64_t)rd32(p + 4) << 32; }
static void wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v, p[1] = (uint8_t)(v >> 8), p[2] = (uint8_t)(v >> 16), p[3] = (uint8_t)(v >> 24);
}

static Res *find(HvVirtioGpu *g, uint32_t id) {
    for (Res *r = g->res[id % BUCKETS]; r; r = r->next)
        if (r->id == id) return r;
    return NULL;
}

static void drop_backing(Res *r) {
    free(r->iov_base), free(r->iov_len), free(r->iov_at);
    r->iov_base = NULL, r->iov_len = NULL, r->iov_at = NULL, r->niov = 0;
}

static void unref(HvVirtioGpu *g, uint32_t id) {
    for (Res **pp = &g->res[id % BUCKETS]; *pp; pp = &(*pp)->next) {
        Res *r = *pp;
        if (r->id != id) continue;
        *pp = r->next;
        if (r->data) g->res_bytes -= (uint64_t)r->width * r->height * 4;
        if (g->has_gl && g->gl.resource_unref) g->gl.resource_unref(g->gl.opaque, id);
        if (g->scanout_res == id) {
            g->scanout_res = 0;
            pthread_mutex_lock(&g->mu);
            free(g->screen.pixels);
            g->screen.pixels = NULL, g->screen.width = g->screen.height = 0;
            pthread_mutex_unlock(&g->mu);
        }
        drop_backing(r);
        free(r->data);
        free(r);
        return;
    }
}

/* Copy len bytes at offset `at` of a resource's backing (guest pages) to dst. */
static int from_backing(const Res *r, uint64_t at, uint8_t *dst, uint64_t len) {
    if (!r->niov) return -1;
    uint32_t lo = 0, hi = r->niov;
    while (hi - lo > 1) { /* the piece holding `at` */
        uint32_t mid = (lo + hi) / 2;
        if (r->iov_at[mid] <= at) lo = mid;
        else hi = mid;
    }
    for (uint32_t i = lo; len && i < r->niov; i++) {
        uint64_t skip = at > r->iov_at[i] ? at - r->iov_at[i] : 0;
        if (skip >= r->iov_len[i]) continue;
        uint64_t n = r->iov_len[i] - skip;
        if (n > len) n = len;
        memcpy(dst, (uint8_t *)r->iov_base[i] + skip, n);
        dst += n, len -= n, at += n;
    }
    return len ? -1 : 0;
}

/* One pixel of a virtio format (named by byte order in memory) as B, G, R, A. */
void hv_vgpu_to_bgra(uint32_t format, const uint8_t *s, uint8_t *d, uint32_t n) {
    switch (format) {
    case 1: case 2: /* B8G8R8A8, B8G8R8X8: as is */
        memcpy(d, s, (size_t)n * 4);
        break;
    case 3: case 4: /* A8R8G8B8, X8R8G8B8 */
        for (uint32_t i = 0; i < n; i++, s += 4, d += 4) d[0] = s[3], d[1] = s[2], d[2] = s[1], d[3] = s[0];
        break;
    case 67: case 134: /* R8G8B8A8, R8G8B8X8 */
        for (uint32_t i = 0; i < n; i++, s += 4, d += 4) d[0] = s[2], d[1] = s[1], d[2] = s[0], d[3] = s[3];
        break;
    case 121: case 68: /* A8B8G8R8, X8B8G8R8 */
        for (uint32_t i = 0; i < n; i++, s += 4, d += 4) d[0] = s[1], d[1] = s[2], d[2] = s[3], d[3] = s[0];
        break;
    default:
        memcpy(d, s, (size_t)n * 4);
        break;
    }
}

/* The resource's rectangle (in resource coordinates) into the screen. */
/* A 3D frame on its way to the presenter: shown from the renderer's thread once the GPU has drawn it. */
typedef struct Showing {
    HvVgpuPresenter pres;
    uint32_t width, height, sx, sy, sw, sh;
} Showing;
static void show_texture(void *ctx, void *texture, int y0top) {
    Showing *s = ctx;
    if (texture) s->pres.texture(s->pres.opaque, texture, s->width, s->height, s->sx, s->sy, s->sw, s->sh, y0top);
}

static void update_screen(HvVirtioGpu *g, Res *r, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    pthread_mutex_lock(&g->mu);
    HvVgpuScreen *s = &g->screen;
    /* Clip to what is scanned out: the screen shows the resource from (sx, sy). */
    uint32_t x0 = x > g->sx ? x : g->sx, y0 = y > g->sy ? y : g->sy;
    uint32_t x1 = x + w, y1 = y + h;
    if (x1 > g->sx + s->width) x1 = g->sx + s->width;
    if (y1 > g->sy + s->height) y1 = g->sy + s->height;
    if (x1 > r->width) x1 = r->width;
    if (y1 > r->height) y1 = r->height;
    if (!s->pixels || x0 >= x1 || y0 >= y1) {
        pthread_mutex_unlock(&g->mu);
        return;
    }
    uint32_t dx = x0 - g->sx, dy = y0 - g->sy, cw = x1 - x0, ch = y1 - y0;
    if (r->data) {
        for (uint32_t row = 0; row < ch; row++)
            hv_vgpu_to_bgra(r->format, r->data + ((uint64_t)(y0 + row) * r->width + x0) * 4,
                    s->pixels + ((uint64_t)(dy + row) * s->width + dx) * 4, cw);
    } else if (g->has_gl) {
        /* A presenter that takes GPU textures shows the scanout as it is, nothing copied; the screen's pixels are
           refreshed now and then for snapshots (the app's preview). */
        void *tex = NULL;
        int y0top = 0, posted = 0;
        if (g->has_pres && g->pres.texture && g->gl.present) {
            /* Without waiting: the guest's CPU goes on while the GPU finishes the frame. */
            Showing sh = {g->pres, r->width, r->height, g->sx, g->sy, s->width, s->height};
            posted = g->gl.present(g->gl.opaque, r->id, show_texture, &sh, sizeof sh) == 0;
        }
        if (!posted && g->has_pres && g->pres.texture && g->gl.native_texture) tex = g->gl.native_texture(g->gl.opaque, r->id, &y0top);
        if (tex) g->pres.texture(g->pres.opaque, tex, r->width, r->height, g->sx, g->sy, s->width, s->height, y0top);
        if (posted || tex) {
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            uint64_t now = (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
            if (now - g->readback_ns > 2000000000ull && g->gl.read_pixels) {
                g->readback_ns = now;
                g->gl.read_pixels(g->gl.opaque, r->id, g->sx, g->sy, s->width, s->height, s->pixels, s->width * 4);
            }
            s->frames++;
            pthread_mutex_unlock(&g->mu);
            return;
        }
        if (g->gl.read_pixels)
            g->gl.read_pixels(g->gl.opaque, r->id, x0, y0, cw, ch, s->pixels + ((uint64_t)dy * s->width + dx) * 4, s->width * 4);
    }
    s->frames++;
    if (g->has_pres && g->pres.pixels) g->pres.pixels(g->pres.opaque, s, dx, dy, cw, ch);
    pthread_mutex_unlock(&g->mu);
}

static void set_scanout(HvVirtioGpu *g, uint32_t res, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    g->scanout_res = res;
    g->sx = x, g->sy = y;
    pthread_mutex_lock(&g->mu);
    HvVgpuScreen *s = &g->screen;
    if (!res || !w || !h) {
        free(s->pixels);
        s->pixels = NULL, s->width = s->height = 0;
    } else if (s->width != w || s->height != h || !s->pixels) {
        free(s->pixels);
        s->pixels = calloc((size_t)w * h, 4);
        s->width = s->pixels ? w : 0, s->height = s->pixels ? h : 0;
    }
    pthread_mutex_unlock(&g->mu);
    if (g->log) fprintf(stderr, "virtio-gpu: scanout resource %u, %ux%u at %u,%u\n", res, w, h, x, y);
}

static void cursor_image(HvVirtioGpu *g, uint32_t res, uint32_t hx, uint32_t hy) {
    Res *r = res ? find(g, res) : NULL;
    pthread_mutex_lock(&g->mu);
    g->cursor_on = 0;
    if (r) {
        memset(g->cursor, 0, sizeof g->cursor);
        uint32_t w = r->width < 64 ? r->width : 64, h = r->height < 64 ? r->height : 64;
        if (r->data) {
            for (uint32_t row = 0; row < h; row++) hv_vgpu_to_bgra(r->format, r->data + (uint64_t)row * r->width * 4, g->cursor + row * 256, w);
            g->cursor_on = 1;
        } else if (g->has_gl && g->gl.read_pixels) {
            g->cursor_on = g->gl.read_pixels(g->gl.opaque, res, 0, 0, w, h, g->cursor, 256) == 0;
        }
        g->hot_x = hx, g->hot_y = hy;
    }
    pthread_mutex_unlock(&g->mu);
}

/* The readable part of a request, whole. */
static uint32_t request(HvVirtioGpu *g, const HvVirtqElem *e) {
    uint32_t n = 0;
    for (int i = 0; i < e->nseg; i++)
        if (!e->seg[i].write) n += e->seg[i].len;
    if (n > g->cmd_cap) {
        uint8_t *bigger = realloc(g->cmd, n);
        if (!bigger) return 0;
        g->cmd = bigger, g->cmd_cap = n;
    }
    return hv_virtq_read(&g->vio, e, 0, g->cmd, n);
}

static void respond(HvVirtioGpu *g, int q, const HvVirtqElem *e, uint8_t *resp, uint32_t len, uint32_t type, const uint8_t *req) {
    memset(resp, 0, HDR);
    wr32(resp, type);
    uint32_t flags = rd32(req + 4);
    if (flags & FLAG_FENCE) {
        wr32(resp + 4, flags & 3); /* FENCE, and RING_IDX if given */
        memcpy(resp + 8, req + 8, 8 + 4 + 1); /* fence id, ctx, ring */
    }
    uint32_t n = hv_virtq_write(&g->vio, e, 0, resp, len);
    hv_virtq_push(&g->vio, q, e, n);
}

static int attach_backing(HvVirtioGpu *g, const uint8_t *c, uint32_t len) {
    if (len < HDR + 8) return RESP_ERR_INVALID_PARAMETER;
    Res *r = find(g, rd32(c + HDR));
    uint32_t n = rd32(c + HDR + 4);
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    if (n == 0 || n > (1u << 20) || len < HDR + 8 + (uint64_t)n * 16) return RESP_ERR_INVALID_PARAMETER;
    drop_backing(r);
    r->iov_base = calloc(n, sizeof *r->iov_base);
    r->iov_len = calloc(n, sizeof *r->iov_len);
    r->iov_at = calloc(n, sizeof *r->iov_at);
    if (!r->iov_base || !r->iov_len || !r->iov_at) {
        drop_backing(r);
        return RESP_ERR_OUT_OF_MEMORY;
    }
    uint64_t at = 0;
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t *ent = c + HDR + 8 + i * 16;
        uint64_t addr = rd64(ent);
        uint32_t l = rd32(ent + 8);
        void *p = hv_phys_ptr(g->vio.m, addr, l);
        if (!p) {
            drop_backing(r);
            return RESP_ERR_INVALID_PARAMETER;
        }
        r->iov_base[i] = p, r->iov_len[i] = l, r->iov_at[i] = at;
        at += l;
    }
    r->niov = n;
    if (r->is3d && g->has_gl && g->gl.attach_backing &&
        g->gl.attach_backing(g->gl.opaque, r->id, r->iov_base, r->iov_len, n) != 0)
        return RESP_ERR_UNSPEC;
    return RESP_OK_NODATA;
}

/* One control command. Returns the response length written into resp (HDR at least), the type in *type. */
static uint32_t command(HvVirtioGpu *g, const uint8_t *c, uint32_t len, uint8_t *resp, uint32_t cap, uint32_t *type) {
    uint32_t cmd = rd32(c), ctx = rd32(c + 16);
    const uint8_t *a = c + HDR;
    uint32_t alen = len - HDR;
    *type = RESP_OK_NODATA;
    if (g->log > 1) fprintf(stderr, "virtio-gpu: command %#x (%u bytes)\n", cmd, len);
    switch (cmd) {
    case CMD_GET_DISPLAY_INFO: {
        if (cap < HDR + 16 * 24) break;
        memset(resp + HDR, 0, 16 * 24);
        wr32(resp + HDR + 8, g->pref_w);
        wr32(resp + HDR + 12, g->pref_h);
        wr32(resp + HDR + 16, 1); /* enabled */
        *type = RESP_OK_DISPLAY_INFO;
        return HDR + 16 * 24;
    }
    case CMD_RESOURCE_CREATE_2D: {
        if (alen < 16) { *type = RESP_ERR_INVALID_PARAMETER; break; }
        uint32_t id = rd32(a), format = rd32(a + 4), w = rd32(a + 8), h = rd32(a + 12);
        uint64_t bytes = (uint64_t)w * h * 4;
        if (!id || find(g, id) || !w || !h || w > 16384 || h > 16384) { *type = RESP_ERR_INVALID_PARAMETER; break; }
        if (g->res_bytes + bytes > MAX_RES_BYTES) { *type = RESP_ERR_OUT_OF_MEMORY; break; }
        Res *r = calloc(1, sizeof *r);
        if (r) r->data = calloc(1, bytes);
        if (!r || !r->data) {
            free(r);
            *type = RESP_ERR_OUT_OF_MEMORY;
            break;
        }
        r->id = id, r->format = format, r->width = w, r->height = h;
        r->next = g->res[id % BUCKETS], g->res[id % BUCKETS] = r;
        g->res_bytes += bytes;
        break;
    }
    case CMD_RESOURCE_UNREF:
        if (alen < 4 || !find(g, rd32(a))) { *type = RESP_ERR_INVALID_RESOURCE_ID; break; }
        unref(g, rd32(a));
        break;
    case CMD_SET_SCANOUT: {
        if (alen < 24) { *type = RESP_ERR_INVALID_PARAMETER; break; }
        uint32_t x = rd32(a), y = rd32(a + 4), w = rd32(a + 8), h = rd32(a + 12), scanout = rd32(a + 16), id = rd32(a + 20);
        if (scanout != 0) { *type = RESP_ERR_INVALID_SCANOUT_ID; break; }
        Res *r = id ? find(g, id) : NULL;
        if (id && !r) { *type = RESP_ERR_INVALID_RESOURCE_ID; break; }
        if (r && ((uint64_t)x + w > r->width || (uint64_t)y + h > r->height)) { *type = RESP_ERR_INVALID_PARAMETER; break; }
        set_scanout(g, id, x, y, w, h);
        if (r) update_screen(g, r, x, y, w, h);
        break;
    }
    case CMD_RESOURCE_FLUSH: {
        if (alen < 20) { *type = RESP_ERR_INVALID_PARAMETER; break; }
        Res *r = find(g, rd32(a + 16));
        if (!r) { *type = RESP_ERR_INVALID_RESOURCE_ID; break; }
        if (r->id == g->scanout_res) update_screen(g, r, rd32(a), rd32(a + 4), rd32(a + 8), rd32(a + 12));
        break;
    }
    case CMD_TRANSFER_TO_HOST_2D: {
        if (alen < 28) { *type = RESP_ERR_INVALID_PARAMETER; break; }
        uint32_t x = rd32(a), y = rd32(a + 4), w = rd32(a + 8), h = rd32(a + 12);
        uint64_t offset = rd64(a + 16);
        Res *r = find(g, rd32(a + 24));
        if (!r) { *type = RESP_ERR_INVALID_RESOURCE_ID; break; }
        if (!r->data) { /* a 3D resource moved as 2D: the renderer's own transfer */
            uint32_t box[6] = {x, y, 0, w, h, 1};
            if (g->has_gl && g->gl.transfer) *type = g->gl.transfer(g->gl.opaque, 1, 0, r->id, box, 0, 0, 0, offset) ? RESP_ERR_UNSPEC : RESP_OK_NODATA;
            break;
        }
        if ((uint64_t)x + w > r->width || (uint64_t)y + h > r->height) { *type = RESP_ERR_INVALID_PARAMETER; break; }
        uint32_t stride = r->width * 4;
        if (x == 0 && w == r->width) { /* whole rows: one copy */
            if (from_backing(r, offset, r->data + (uint64_t)y * stride, (uint64_t)h * stride)) *type = RESP_ERR_UNSPEC;
            break;
        }
        for (uint32_t row = 0; row < h; row++)
            if (from_backing(r, offset + (uint64_t)row * stride, r->data + (uint64_t)(y + row) * stride + x * 4, (uint64_t)w * 4)) {
                *type = RESP_ERR_UNSPEC;
                break;
            }
        break;
    }
    case CMD_RESOURCE_ATTACH_BACKING:
        *type = (uint32_t)attach_backing(g, c, len);
        break;
    case CMD_RESOURCE_DETACH_BACKING: {
        Res *r = alen >= 4 ? find(g, rd32(a)) : NULL;
        if (!r) { *type = RESP_ERR_INVALID_RESOURCE_ID; break; }
        if (r->is3d && g->has_gl && g->gl.detach_backing) g->gl.detach_backing(g->gl.opaque, r->id);
        drop_backing(r);
        break;
    }
    case CMD_GET_CAPSET_INFO: {
        uint32_t id = 0, ver = 0, size = 0;
        if (alen < 4 || !g->has_gl || g->gl.capset_info(g->gl.opaque, rd32(a), &id, &ver, &size) != 0) {
            *type = RESP_ERR_INVALID_PARAMETER;
            break;
        }
        memset(resp + HDR, 0, 16);
        wr32(resp + HDR, id), wr32(resp + HDR + 4, ver), wr32(resp + HDR + 8, size);
        *type = RESP_OK_CAPSET_INFO;
        return HDR + 16;
    }
    case CMD_GET_CAPSET: {
        uint32_t id = alen >= 8 ? rd32(a) : 0, ver = alen >= 8 ? rd32(a + 4) : 0, size = 0;
        for (uint32_t i = 0; g->has_gl && i < g->gl.ncapsets; i++) {
            uint32_t cid, cver, csize;
            if (g->gl.capset_info(g->gl.opaque, i, &cid, &cver, &csize) == 0 && cid == id) size = csize;
        }
        if (!size || HDR + size > cap || g->gl.capset(g->gl.opaque, id, ver, resp + HDR, size) != 0) {
            *type = RESP_ERR_INVALID_PARAMETER;
            break;
        }
        *type = RESP_OK_CAPSET;
        return HDR + size;
    }
    case CMD_CTX_CREATE:
        if (!g->has_gl || alen < 8) { *type = RESP_ERR_UNSPEC; break; }
        {
            uint32_t nlen = rd32(a), init = rd32(a + 4);
            if (nlen > 64 || alen < 8 + nlen) nlen = 0;
            *type = g->gl.ctx_create(g->gl.opaque, ctx, init, (const char *)a + 8, nlen) ? RESP_ERR_UNSPEC : RESP_OK_NODATA;
        }
        break;
    case CMD_CTX_DESTROY:
        if (g->has_gl) g->gl.ctx_destroy(g->gl.opaque, ctx);
        break;
    case CMD_CTX_ATTACH_RESOURCE:
    case CMD_CTX_DETACH_RESOURCE:
        if (!g->has_gl || alen < 4) { *type = RESP_ERR_UNSPEC; break; }
        (cmd == CMD_CTX_ATTACH_RESOURCE ? g->gl.ctx_attach : g->gl.ctx_detach)(g->gl.opaque, ctx, rd32(a));
        break;
    case CMD_RESOURCE_CREATE_3D: {
        if (!g->has_gl || alen < 48) { *type = RESP_ERR_UNSPEC; break; }
        uint32_t id = rd32(a), args[10];
        for (int i = 0; i < 10; i++) args[i] = rd32(a + 4 + 4 * i);
        if (!id || find(g, id)) { *type = RESP_ERR_INVALID_RESOURCE_ID; break; }
        Res *r = calloc(1, sizeof *r);
        if (!r) { *type = RESP_ERR_OUT_OF_MEMORY; break; }
        if (g->gl.resource_create_3d(g->gl.opaque, id, args) != 0) {
            free(r);
            *type = RESP_ERR_UNSPEC;
            break;
        }
        r->id = id, r->is3d = 1, r->format = args[1], r->width = args[3], r->height = args[4];
        r->next = g->res[id % BUCKETS], g->res[id % BUCKETS] = r;
        break;
    }
    case CMD_TRANSFER_TO_HOST_3D:
    case CMD_TRANSFER_FROM_HOST_3D: {
        if (!g->has_gl || alen < 48) { *type = RESP_ERR_UNSPEC; break; }
        uint32_t box[6];
        for (int i = 0; i < 6; i++) box[i] = rd32(a + 4 * i);
        Res *r = find(g, rd32(a + 32));
        if (!r) { *type = RESP_ERR_INVALID_RESOURCE_ID; break; }
        *type = g->gl.transfer(g->gl.opaque, cmd == CMD_TRANSFER_TO_HOST_3D, ctx, r->id, box, rd32(a + 36), rd32(a + 40), rd32(a + 44),
                               rd64(a + 24)) ? RESP_ERR_UNSPEC : RESP_OK_NODATA;
        break;
    }
    case CMD_SUBMIT_3D: {
        if (!g->has_gl || alen < 8) { *type = RESP_ERR_UNSPEC; break; }
        uint32_t size = rd32(a);
        if (size > alen - 8) { *type = RESP_ERR_INVALID_PARAMETER; break; }
        atomic_fetch_add(&g->submits, 1);
        atomic_fetch_add(&g->submit_bytes, size);
        *type = g->gl.submit(g->gl.opaque, ctx, (void *)(a + 8), size) ? RESP_ERR_UNSPEC : RESP_OK_NODATA;
        break;
    }
    default:
        if (g->log) fprintf(stderr, "virtio-gpu: command %#x not handled\n", cmd);
        *type = RESP_ERR_UNSPEC;
        break;
    }
    return HDR;
}

static void ctrl(HvVirtioGpu *g) {
    static HvVirtqElem e;
    static uint8_t resp[HDR + 64 * 1024];
    int any = 0;
    while (hv_virtq_pop(&g->vio, CTRLQ, &e) > 0) {
        uint32_t len = request(g, &e), type;
        if (len < HDR) {
            static const uint8_t none[HDR];
            respond(g, CTRLQ, &e, resp, HDR, RESP_ERR_UNSPEC, none);
            any = 1;
            continue;
        }
        uint32_t out = command(g, g->cmd, len, resp, sizeof resp, &type);
        uint32_t flags = rd32(g->cmd + 4);
        if ((flags & FLAG_FENCE) && g->has_gl && g->gl.create_fence && g->npending < MAX_PENDING && out == HDR) {
            /* Answered once the renderer has run everything before the fence. */
            uint64_t fence = rd64(g->cmd + 8);
            Pending *p = &g->pending[g->npending++];
            p->e = e, p->fence = fence;
            memset(p->resp, 0, HDR);
            wr32(p->resp, type);
            wr32(p->resp + 4, flags & 3);
            memcpy(p->resp + 8, g->cmd + 8, 13);
            g->gl.create_fence(g->gl.opaque, rd32(g->cmd + 16), g->cmd[20], fence);
            continue;
        }
        if (g->log && type >= RESP_ERR_UNSPEC) fprintf(stderr, "virtio-gpu: command %#x -> %#x\n", rd32(g->cmd), type);
        /* resp holds the payload after HDR; respond() fills the header. */
        respond(g, CTRLQ, &e, resp, out, type, g->cmd);
        any = 1;
    }
    if (any) hv_virtio_interrupt(&g->vio);
}

static void cursorq(HvVirtioGpu *g) {
    static HvVirtqElem e;
    uint8_t c[HDR + 32] = {0};
    int any = 0;
    while (hv_virtq_pop(&g->vio, CURSORQ, &e) > 0) {
        uint32_t len = hv_virtq_read(&g->vio, &e, 0, c, sizeof c);
        if (len >= HDR + 24) {
            uint32_t cmd = rd32(c);
            int32_t x = (int32_t)rd32(c + HDR + 4), y = (int32_t)rd32(c + HDR + 8);
            if (cmd == CMD_UPDATE_CURSOR) cursor_image(g, rd32(c + HDR + 16), rd32(c + HDR + 20), len >= HDR + 28 ? rd32(c + HDR + 24) : 0);
            pthread_mutex_lock(&g->mu);
            g->cur_x = x, g->cur_y = y;
            if (g->has_pres && g->pres.cursor) g->pres.cursor(g->pres.opaque); /* a frame with the pointer in its new place */
            pthread_mutex_unlock(&g->mu);
        }
        hv_virtq_push(&g->vio, CURSORQ, &e, 0); /* no response */
        any = 1;
    }
    if (any) hv_virtio_interrupt(&g->vio);
}

static void notify(HvVirtio *v, int q) {
    HvVirtioGpu *g = v->dev;
    if (q == CTRLQ) ctrl(g);
    else if (q == CURSORQ) cursorq(g);
}

static void config_write(HvVirtio *v, uint32_t off, uint64_t val, unsigned size) {
    (void)size;
    if (off == 4) { /* events_clear */
        uint32_t read = rd32(v->config) & ~(uint32_t)val;
        wr32(v->config, read);
    }
}

void hv_virtio_gpu_poll(HvVirtioGpu *g) {
    if (!g) return;
    uint64_t want = atomic_exchange(&g->want_size, 0);
    if (want) {
        g->pref_w = (uint32_t)(want >> 32), g->pref_h = (uint32_t)want;
        wr32(g->vio.config, rd32(g->vio.config) | EVENT_DISPLAY);
        if (g->vio.status & 4) hv_virtio_config_changed(&g->vio);
    }
    if (!g->has_gl) return;
    if (g->gl.poll) g->gl.poll(g->gl.opaque);
    uint64_t done = atomic_load(&g->fence_done);
    uint32_t keep = 0;
    int any = 0;
    for (uint32_t i = 0; i < g->npending; i++) {
        Pending *p = &g->pending[i];
        if (p->fence <= done) {
            uint32_t n = hv_virtq_write(&g->vio, &p->e, 0, p->resp, HDR);
            hv_virtq_push(&g->vio, CTRLQ, &p->e, n);
            any = 1;
        } else {
            if (keep != i) g->pending[keep] = *p;
            keep++;
        }
    }
    g->npending = keep;
    if (any) hv_virtio_interrupt(&g->vio);
}

void hv_virtio_gpu_fence_done(HvVirtioGpu *g, uint32_t ctx, uint32_t ring, uint64_t fence) {
    (void)ctx, (void)ring;
    uint64_t was = atomic_load(&g->fence_done);
    while (fence > was && !atomic_compare_exchange_weak(&g->fence_done, &was, fence)) {
    }
    hv_machine_wake(g->vio.m);
}

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, uint32_t width, uint32_t height, const HvVgpu3d *gl) {
    HvVirtioGpu *g = calloc(1, sizeof *g);
    if (g) atomic_store(&g->host_at, 0xffffffff);
    if (!g) return NULL;
    if (gl) {
        g->gl = *gl;
        g->has_gl = 1;
        g->pending = calloc(MAX_PENDING, sizeof *g->pending);
        if (!g->pending) g->has_gl = 0;
    }
    HvVirtio *v = &g->vio;
    hv_virtio_init(v, m, 16, 0x038000, 2, g->has_gl ? F_VIRGL : 0); /* display controller, "other" */
    v->dev = g;
    v->notify = notify;
    v->config_write = config_write;
    v->config_len = 16;
    wr32(v->config + 8, 1);                                /* num_scanouts */
    wr32(v->config + 12, g->has_gl ? g->gl.ncapsets : 0); /* num_capsets */
    g->pref_w = width ? width : 1280, g->pref_h = height ? height : 800;
    g->log = getenv("HV_VGPU_LOG") ? atoi(getenv("HV_VGPU_LOG")) + 1 : 0;
    pthread_mutex_init(&g->mu, NULL);
    hv_pcie_attach(bus, &v->pci);
    return g;
}

void hv_virtio_gpu_destroy(HvVirtioGpu *g) {
    if (!g) return;
    for (int b = 0; b < BUCKETS; b++)
        while (g->res[b]) unref(g, g->res[b]->id);
    free(g->screen.pixels);
    free(g->pending);
    free(g->cmd);
    pthread_mutex_destroy(&g->mu);
    free(g);
}

/* Under mu: where the pointer is drawn, the host's place when it set one. */
static void pointer_place(HvVirtioGpu *g, int32_t *x, int32_t *y) {
    uint32_t at = atomic_load(&g->host_at);
    if (at == 0xffffffff) *x = g->cur_x, *y = g->cur_y;
    else *x = (int32_t)(at & 0xffff), *y = (int32_t)(at >> 16);
}

int hv_virtio_gpu_snapshot(HvVirtioGpu *g, uint8_t **pixels, uint32_t *width, uint32_t *height) {
    if (!g) return -1;
    pthread_mutex_lock(&g->mu);
    HvVgpuScreen *s = &g->screen;
    uint8_t *copy = s->pixels ? malloc((size_t)s->width * s->height * 4) : NULL;
    if (!copy) {
        pthread_mutex_unlock(&g->mu);
        return -1;
    }
    memcpy(copy, s->pixels, (size_t)s->width * s->height * 4);
    uint32_t w = s->width, h = s->height;
    if (g->cursor_on) { /* the pointer, blended in */
        int32_t cx0, cy0;
        pointer_place(g, &cx0, &cy0);
        int32_t ox = cx0 - (int32_t)g->hot_x, oy = cy0 - (int32_t)g->hot_y;
        for (int32_t cy = 0; cy < 64; cy++) {
            int32_t py = oy + cy;
            if (py < 0 || py >= (int32_t)h) continue;
            for (int32_t cx = 0; cx < 64; cx++) {
                int32_t px = ox + cx;
                if (px < 0 || px >= (int32_t)w) continue;
                const uint8_t *c = g->cursor + cy * 256 + cx * 4;
                uint8_t *d = copy + ((size_t)py * w + px) * 4;
                unsigned al = c[3];
                if (!al) continue;
                for (int k = 0; k < 3; k++) d[k] = (uint8_t)((c[k] * al + d[k] * (255 - al)) / 255);
            }
        }
    }
    pthread_mutex_unlock(&g->mu);
    *pixels = copy, *width = w, *height = h;
    return 0;
}

uint64_t hv_virtio_gpu_frames(HvVirtioGpu *g) {
    if (!g) return 0;
    pthread_mutex_lock(&g->mu);
    uint64_t f = g->screen.frames;
    pthread_mutex_unlock(&g->mu);
    return f;
}

void hv_virtio_gpu_stats(HvVirtioGpu *g, uint64_t out[3]) {
    out[0] = hv_virtio_gpu_frames(g);
    out[1] = g ? atomic_load(&g->submits) : 0;
    out[2] = g ? atomic_load(&g->submit_bytes) : 0;
}

void hv_virtio_gpu_set_presenter(HvVirtioGpu *g, const HvVgpuPresenter *p) {
    if (!g) return;
    pthread_mutex_lock(&g->mu);
    g->has_pres = p != NULL;
    if (p) g->pres = *p;
    g->readback_ns = 0;
    pthread_mutex_unlock(&g->mu);
    /* Frames already on their way to the old presenter get there before it goes. */
    if (!p && g->has_gl && g->gl.drain) g->gl.drain(g->gl.opaque);
}

void hv_virtio_gpu_pointer_at(HvVirtioGpu *g, double x, double y) {
    if (!g) return;
    uint32_t at = 0xffffffff;
    pthread_mutex_lock(&g->mu);
    uint32_t w = g->screen.width, h = g->screen.height;
    if (x >= 0 && y >= 0 && w && h) {
        if (x > 1) x = 1;
        if (y > 1) y = 1;
        at = ((uint32_t)(x * (w - 1) + 0.5) & 0xffff) | ((uint32_t)(y * (h - 1) + 0.5) & 0xffff) << 16;
    }
    atomic_store(&g->host_at, at);
    int pres = g->has_pres && g->pres.cursor;
    HvVgpuPresenter p = g->pres;
    pthread_mutex_unlock(&g->mu);
    if (pres) p.cursor(p.opaque); /* the arrow in its new place now, not when the guest moves it */
}

int hv_virtio_gpu_cursor(HvVirtioGpu *g, uint8_t out[64 * 64 * 4], uint32_t *hot_x, uint32_t *hot_y, int32_t *x, int32_t *y) {
    pthread_mutex_lock(&g->mu);
    int on = g->cursor_on;
    if (on) memcpy(out, g->cursor, sizeof g->cursor);
    *hot_x = g->hot_x, *hot_y = g->hot_y;
    pointer_place(g, x, y);
    pthread_mutex_unlock(&g->mu);
    return on;
}

void hv_virtio_gpu_set_size(HvVirtioGpu *g, uint32_t width, uint32_t height) {
    if (!g || !width || !height) return;
    atomic_store(&g->want_size, (uint64_t)width << 32 | height);
    hv_machine_wake(g->vio.m);
}
