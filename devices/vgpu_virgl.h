// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef HENGEVM_VGPU_VIRGL_H
#define HENGEVM_VGPU_VIRGL_H

#include "virtio_gpu.h"

/* 3D for virtio-gpu through virglrenderer: the guest's Mesa (its virgl
   driver) sends Gallium commands, which virglrenderer runs on the host's
   OpenGL or OpenGL ES: Mesa's on a Linux host (llvmpipe or a real GPU,
   surfaceless EGL), ANGLE's on Apple devices, which draws with Metal.

   virglrenderer and its GL contexts live on one thread of their own: the
   guest's commands come from whichever CPU rang the doorbell, so each call is
   handed to that thread and waited for. Fences are retired there too.

   On Apple devices (HV_VIRGL_ANGLE) virglrenderer cannot open a display of its own: the display is ANGLE's
   on Metal, made here, and virglrenderer asks for its contexts (as QEMU does in UTM). HV_VIRGL_OWN_EGL in the
   environment takes that path on Linux too, with Mesa's surfaceless EGL, to try it without a phone.

   Built only with HV_VIRGL (make linux-test LX_VIRGL=1, or the app with
   virglrenderer and ANGLE); without it hv_vgpu_virgl_create returns NULL. */
typedef struct HvVgpuVirgl HvVgpuVirgl;

/* Starts virglrenderer and fills gl with its renderer. gles: OpenGL ES (ANGLE) rather than desktop GL. NULL if it cannot. */
HvVgpuVirgl *hv_vgpu_virgl_create(HvVgpu3d *gl, int gles);
/* The device whose fences it retires: right after hv_virtio_gpu_create. */
void hv_vgpu_virgl_bind(HvVgpuVirgl *v, HvVirtioGpu *g);
void hv_vgpu_virgl_destroy(HvVgpuVirgl *v);

#endif
