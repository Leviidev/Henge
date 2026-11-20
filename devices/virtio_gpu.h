// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef HENGEVM_VIRTIO_GPU_H
#define HENGEVM_VIRTIO_GPU_H

#include <pthread.h>
#include <stdint.h>

#include "virtio.h"

/* virtio-gpu (device type 16) for the Linux machine: Linux's virtio_gpu DRM
   driver, so the guest has a real display (modes, page flips, a hardware
   pointer, damage) instead of a firmware framebuffer.

   2D: the guest's resources live in host memory, filled from guest pages by
   TRANSFER_TO_HOST_2D; RESOURCE_FLUSH on the scanned-out resource copies the
   damaged rectangle into the screen, a BGRA image the host reads
   (hv_virtio_gpu_snapshot, or a presenter called on every flush).

   3D (virgl) goes to a backend when one is set (hv_virtio_gpu_set_3d, before the
   guest starts): the device then offers VIRTIO_GPU_F_VIRGL and hands the 3D
   commands to it. Commands run when the driver notifies, on that CPU's thread,
   with the device lock held. */

typedef struct HvVirtioGpu HvVirtioGpu;

/* A 3D renderer (virglrenderer, devices/vgpu_virgl.c). Resource ids are the guest's.
   Each returns 0 or a VIRTIO_GPU_RESP_ERR_* code. */
typedef struct HvVgpu3d {
    void *opaque;
    uint32_t ncapsets;
    int (*capset_info)(void *o, uint32_t index, uint32_t *id, uint32_t *max_version, uint32_t *max_size);
    int (*capset)(void *o, uint32_t id, uint32_t version, void *out, uint32_t size);
    int (*ctx_create)(void *o, uint32_t ctx, uint32_t context_init, const char *name, uint32_t name_len);
    void (*ctx_destroy)(void *o, uint32_t ctx);
    void (*ctx_attach)(void *o, uint32_t ctx, uint32_t res);
    void (*ctx_detach)(void *o, uint32_t ctx, uint32_t res);
    int (*resource_create_3d)(void *o, uint32_t res, const uint32_t args[10]); /* target format bind width height depth array_size last_level nr_samples flags */
    int (*resource_create_2d)(void *o, uint32_t res, uint32_t format, uint32_t width, uint32_t height);
    void (*resource_unref)(void *o, uint32_t res);
    /* The guest pages behind a resource: iov of host pointers. */
    int (*attach_backing)(void *o, uint32_t res, void **iov_base, uint32_t *iov_len, uint32_t n);
    void (*detach_backing)(void *o, uint32_t res);
    int (*transfer)(void *o, int to_host, uint32_t ctx, uint32_t res, const uint32_t box[6], uint32_t level, uint32_t stride,
                    uint32_t layer_stride, uint64_t offset);
    int (*submit)(void *o, uint32_t ctx, void *cmd, uint32_t size);
    /* A fence: done() is called (from poll) once the commands before it have run. */
    int (*create_fence)(void *o, uint32_t ctx, uint32_t ring, uint64_t fence);
    void (*poll)(void *o);
    /* A resource's pixels as BGRA rows into out (width * 4 per row), for the screen. 0 if it could. */
    int (*read_pixels)(void *o, uint32_t res, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t *out, uint32_t out_stride);
    /* The GPU texture behind a 3D resource, once what was drawn into it is finished, retained for the caller (on
       Apple an MTLTexture, released with CFRelease); *y0top: its rows are stored bottom first. NULL: none (read_pixels). */
    void *(*native_texture)(void *o, uint32_t res, int *y0top);
    /* The same without waiting (NULL: not offered): once the GPU has drawn what came before, show(ctx, texture,
       y0top) runs on the renderer's thread, texture NULL when there is none; ctx is copied (at most 64 bytes). */
    int (*present)(void *o, uint32_t res, void (*show)(void *ctx, void *texture, int y0top), const void *ctx, size_t ctx_size);
    /* Waits until everything asked of the renderer so far has run (NULL: nothing runs later). */
    void (*drain)(void *o);
} HvVgpu3d;

typedef struct HvVgpuScreen {
    uint32_t width, height; /* 0 x 0: nothing scanned out */
    uint8_t *pixels;        /* BGRA, width * 4 per row */
    uint64_t frames;        /* flushes so far */
} HvVgpuScreen;

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, uint32_t width, uint32_t height, const HvVgpu3d *gl);
void hv_virtio_gpu_destroy(HvVirtioGpu *g);
/* Fences the 3D backend has finished: from the board's tick. Device lock held. */
void hv_virtio_gpu_poll(HvVirtioGpu *g);
/* The 3D backend says a fence is done (any thread). */
void hv_virtio_gpu_fence_done(HvVirtioGpu *g, uint32_t ctx, uint32_t ring, uint64_t fence);

/* Any thread: a copy of the screen with the pointer drawn in, to free(). 0, or -1 when nothing is scanned out. */
int hv_virtio_gpu_snapshot(HvVirtioGpu *g, uint8_t **pixels, uint32_t *width, uint32_t *height);
uint64_t hv_virtio_gpu_frames(HvVirtioGpu *g);
/* Screen updates (flushes), 3D command buffers and their bytes, so far. g may be NULL (all 0). */
void hv_virtio_gpu_stats(HvVirtioGpu *g, uint64_t out[3]);
/* Something that shows the screen itself (devices/vgpu_metal.m), told of every change. Called with the screen locked,
   from the guest's CPU threads: they must not block or call back into the device.
   pixels: the screen's BGRA pixels changed in (x, y, w, h).
   texture: a 3D scanout was drawn: its GPU texture (retained, the presenter releases it), the resource's size, the part
            scanned out, and whether its rows are stored bottom first. The screen's pixels are then not kept up to date
            (only every few seconds, for snapshots).
   cursor: the pointer moved or changed (hv_virtio_gpu_cursor). */
typedef struct HvVgpuPresenter {
    void *opaque;
    void (*pixels)(void *opaque, const HvVgpuScreen *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h);
    void (*texture)(void *opaque, void *texture, uint32_t width, uint32_t height, uint32_t sx, uint32_t sy, uint32_t sw,
                    uint32_t sh, int y0top);
    void (*cursor)(void *opaque);
} HvVgpuPresenter;
/* Any thread; NULL takes it away. */
void hv_virtio_gpu_set_presenter(HvVirtioGpu *g, const HvVgpuPresenter *p);
/* The pointer: its image (BGRA 64 x 64, hot spot) and where it is, as the guest last set them. */
/* Any thread: draw the pointer at (x, y), fractions of the screen, instead of where the guest has it (the
   iPhone's pointer, shown at once while the guest catches up); x < 0 gives the place back to the guest. */
void hv_virtio_gpu_pointer_at(HvVirtioGpu *g, double x, double y);
int hv_virtio_gpu_cursor(HvVirtioGpu *g, uint8_t out[64 * 64 * 4], uint32_t *hot_x, uint32_t *hot_y, int32_t *x, int32_t *y);
/* The size the guest is told its display prefers (e.g. the phone turned): a display change event. Any thread. */
void hv_virtio_gpu_set_size(HvVirtioGpu *g, uint32_t width, uint32_t height);
/* n pixels of a virtio-gpu (= Gallium/virgl) format, named by byte order in memory, as B, G, R, A. */
void hv_vgpu_to_bgra(uint32_t format, const uint8_t *s, uint8_t *d, uint32_t n);

#endif
