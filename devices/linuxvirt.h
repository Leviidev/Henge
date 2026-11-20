// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef HENGEVM_LINUXVIRT_H
#define HENGEVM_LINUXVIRT_H

#include <stddef.h>
#include <stdint.h>

#include "machine.h"
#include "virtio_gpu.h"
#include "vmapple.h"

/* A generic arm64 machine for Linux guests, on the same engine and devices as
   the virtual Mac and at the same addresses (devices/vmapple.h), but booted the
   way Linux boots on any arm64 board: the kernel Image is loaded directly, a
   device tree describing the machine goes in x0, and there is no boot ROM.

   Devices Linux drives with its stock drivers: GICv3, the generic timer, PL011
   (console), PL031 (clock), PSCI over HVC (CPU_ON, shutdown, reset), a generic
   ECAM PCIe host with INTx, and on it virtio-pci block, network, input and
   sound, and the xHCI controller with the virtual Mac's USB keyboard and Magic
   Trackpad 2 (usbhid, hid-magicmouse). An optional simple-framebuffer at the
   top of RAM, or virtio-gpu (devices/virtio_gpu.h), is the display. See docs/linux-machine.md.

   The devices live in an HvVmapple, the virtual Mac's board, so the code that
   feeds the Mac input, disks, network and sound serves this machine unchanged;
   the Mac-only devices (boot ROM, AES, GPU, ...) stay NULL. */
typedef struct HvLinuxVirt {
    HvVmapple *board;
    /* Framebuffer (simple-framebuffer, a8r8g8b8: B, G, R, A in memory) carved
       from the top of RAM; NULL when there is none. */
    uint8_t *fb;
    uint32_t fb_width, fb_height;
    uint64_t fb_pa;
    /* virtio-gpu, the display when there is one (no framebuffer then). Kept here, not in the
       board, so the virtual Mac's saved-state layout (host/snapshot.c) is unchanged. */
    HvVirtioGpu *gpu;
    /* The absolute pointer (after the display, so the other slots stay where they were). */
    HvVirtioInput *tablet;
    /* Where the boot images went (guest physical). */
    uint64_t kernel_pa, dtb_pa, initrd_pa, initrd_size;
} HvLinuxVirt;

typedef struct HvLinuxVirtConfig {
    int ncpus;
    uint64_t ram_size;
    HvDisk *disk;           /* virtio-blk root disk (/dev/vda), or NULL */
    const uint8_t *mac;     /* virtio-net MAC, or NULL for no network device */
    int usb;                /* the xHCI controller with the USB keyboard and trackpad */
    int sound;              /* virtio-snd */
    uint32_t fb_width, fb_height; /* 0 x 0: no framebuffer; with gpu, the size the display prefers */
    int gpu;                /* virtio-gpu instead of the framebuffer */
    const HvVgpu3d *gl;     /* and its 3D renderer (virgl), or NULL for 2D */
    const char *cmdline;    /* kernel command line */
} HvLinuxVirtConfig;

/* Builds the machine into b. b must be zeroed with b->ram_fd = -1; if b->ram
   is already set (hv_vmapple_alloc_ram) it must be c->ram_size long and is
   used as guest RAM, else anonymous memory is mapped. 0, or -1. */
int hv_linuxvirt_create(HvLinuxVirt *lv, HvVmapple *b, HvMachine *m, HvCpu *cpus, const HvLinuxVirtConfig *c);
/* Loads an uncompressed arm64 Image (and an initrd, may be NULL), writes the
   device tree and puts every CPU at reset: CPU 0 at the kernel with x0 = the
   device tree, the others off until PSCI CPU_ON. 0, or -1 with err filled in. */
int hv_linuxvirt_boot(HvLinuxVirt *lv, const HvLinuxVirtConfig *c, const uint8_t *image, size_t image_len,
                      const uint8_t *initrd, size_t initrd_len, char *err, size_t errlen);
/* Reads the kernel (and initrd, may be NULL) from files and boots them. */
int hv_linuxvirt_boot_files(HvLinuxVirt *lv, const HvLinuxVirtConfig *c, const char *kernel, const char *initrd,
                            char *err, size_t errlen);
/* For a board built here, when the virtual Mac's hv_vmapple_destroy is not linked in (tools/hengelinux). */
void hv_linuxvirt_destroy(HvLinuxVirt *lv);

#endif
