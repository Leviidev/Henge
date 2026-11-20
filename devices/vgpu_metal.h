// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef HENGEVM_VGPU_METAL_H
#define HENGEVM_VGPU_METAL_H

#include <stdint.h>

#include "virtio_gpu.h"

/* The Linux machine's screen drawn by the GPU onto the app's CAMetalLayer (the
   layer the virtual Mac's display uses), instead of copied into an image by
   the CPU 60 times a second. It registers itself as the virtio-gpu device's
   presenter: a 2D screen's changed rectangles go into a texture of its own; a
   3D scanout is shown as its own Metal texture (the one ANGLE drew into), with
   nothing copied. The pointer is drawn on top. Frames are shown on a queue of
   its own, never on the guest's CPU threads. Apple platforms only. */
typedef struct HvVgpuMetal HvVgpuMetal;

/* NULL without a Metal device. */
HvVgpuMetal *hv_vgpu_metal_create(HvVirtioGpu *gpu);
/* The CAMetalLayer to draw on, or NULL. Any thread. */
void hv_vgpu_metal_set_layer(HvVgpuMetal *p, void *layer);
/* Frames shown on a layer so far. */
uint64_t hv_vgpu_metal_frames(HvVgpuMetal *p);
/* Leaves the device (before it is destroyed) and waits for a frame being drawn. */
void hv_vgpu_metal_destroy(HvVgpuMetal *p);

#endif
