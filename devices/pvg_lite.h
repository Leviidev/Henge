#ifndef HENGEVM_PVG_LITE_H
#define HENGEVM_PVG_LITE_H

#include <stdint.h>

#include "gicv3.h"

/* HengeVM's own graphics device, for hosts without
   ParavirtualizedGraphics.framework (iOS). It speaks the protocol of Apple's
   guest driver (AppleParavirtGPU) so the driver starts and its commands
   complete; pvg_metal.m runs what they draw. */
typedef struct HvPvgLite HvPvgLite;

HvPvgLite *hv_pvg_lite_create(HvMachine *m, HvGic *gic, uint64_t gfx_pa, uint64_t iosfc_pa, int gfx_irq, int iosfc_irq);
void hv_pvg_lite_destroy(HvPvgLite *p);
/* Completes doorbells rung since the last call. Device lock held. */
void hv_pvg_lite_poll(HvPvgLite *p);
/* The newest frame, BGRA, width * 4 bytes per row, if drawing has produced one. Returns 0 if so. */
int hv_pvg_lite_frame(HvPvgLite *p, const uint8_t **pixels, uint32_t *width, uint32_t *height);

/* Between the device and its Metal side (pvg_metal.m). */
typedef struct HvPvgMetal HvPvgMetal;
HvPvgMetal *hv_pvg_metal_create(HvPvgLite *lite);
void hv_pvg_metal_destroy(HvPvgMetal *m);
/* Reserve before producer metadata mutation; false leaves the ring pending. */
/* 0: no shader wait, 1: preparing/waiting, 2: terminal retained-work fault. */
int hv_pvg_metal_render_status(HvPvgMetal *m,char *message,uint32_t length);
int hv_pvg_lite_render_status(HvPvgLite *p,char *message,uint32_t length);
int hv_pvg_metal_reserve(HvPvgMetal *m,uint32_t length);
void hv_pvg_metal_drain(HvPvgMetal *m,void(*done)(void*,int cancelled),void *opaque);
void hv_pvg_lite_drain(HvPvgLite *p,void(*done)(void*,int cancelled),void *opaque);
void hv_pvg_metal_submit(HvPvgMetal *m, HvPvgLite *lite, uint32_t channel, uint32_t *command, uint32_t length);
int hv_pvg_metal_snapshot(HvPvgMetal *m, uint8_t *bgra, uint32_t width, uint32_t height);
int hv_pvg_lite_snapshot(HvPvgLite *p, uint8_t *bgra, uint32_t width, uint32_t height);
int hv_pvg_metal_frame(HvPvgMetal *m, const uint8_t **pixels, uint32_t *width, uint32_t *height);
/* Worker-local view of producer metadata, captured when a command is accepted.
 * Guest-owned page mappings remain valid until its completion stamp. */
typedef struct {uint32_t task,top,depth;uint64_t objects,generation;} HvPvgTaskView;
int hv_pvg_lite_task_view(HvPvgLite *p,uint32_t task,HvPvgTaskView *view);
void hv_pvg_lite_use_task_view(HvPvgLite *p,const HvPvgTaskView *view);
int hv_pvg_lite_task_read(HvPvgLite *p, uint32_t task, uint64_t offset, void *to, uint32_t length);
uint32_t hv_pvg_lite_task_page(HvPvgLite *p, uint32_t task, uint64_t offset);
uint8_t *hv_pvg_lite_page(HvPvgLite *p, uint32_t guest_page);
void *hv_pvg_lite_phys(HvPvgLite *p, uint64_t pa, uint64_t length);
uint64_t hv_pvg_lite_task_objects(HvPvgLite *p, uint32_t task);
/* Changes on each create, even when the root/table addresses are reused. */
uint64_t hv_pvg_lite_task_generation(HvPvgLite *p, uint32_t task);
/* The mapper selected compact 512-byte descriptors instead of 1 KiB descriptors. */
int hv_pvg_lite_compact_surfaces(HvPvgLite *p);
/* A surface descriptor in the mapper's selected format, or NULL. */
const uint8_t *hv_pvg_lite_surface(HvPvgLite *p, uint32_t mapping);
/* Mapper entries complete behind preceding accepted GPU work. */
void hv_pvg_metal_mapper(HvPvgMetal *m,uint32_t operation,uint32_t mapping,uint64_t completed_index);
void hv_pvg_lite_mapper_complete(HvPvgLite *p,uint64_t completed_index);
void hv_pvg_metal_cursor_moved(HvPvgMetal *m);
/* Frames go to this CAMetalLayer from now on, drawn by the GPU. Any thread. */
void hv_pvg_metal_set_layer(HvPvgMetal *m, void *layer);
uint64_t hv_pvg_metal_gpu_frames(HvPvgMetal *m);
void hv_pvg_lite_task_pages(HvPvgLite *p, uint32_t task, uint64_t first, uint64_t n, uint32_t *out);
void hv_pvg_lite_set_layer(HvPvgLite *p, void *layer);
uint64_t hv_pvg_lite_gpu_frames(HvPvgLite *p);
void hv_pvg_lite_barrier_stats(HvPvgLite *p, uint64_t out[4]);
/* The display's shared state page, or NULL before the guest named it. */
uint8_t *hv_pvg_lite_display_page(HvPvgLite *p);
void hv_pvg_lite_command(HvPvgLite *p, const uint32_t *command, uint32_t length);
void hv_pvg_lite_complete(HvPvgLite *p, uint32_t channel, uint32_t stamp);

/* Whether the file HV_PVG_TRACE_FILE names exists (tracing asked for while the guest runs): looked at no more than
   every 100 ms, as it was asked for every command (thousands a second, ~0.5% of busy time on the phone). */
int hv_pvg_trace_on(void);

/* The size macOS is told its screen is. Set before the machine starts; default 1920 x 1080. */
void hv_pvg_lite_set_mode(uint32_t width, uint32_t height);
void hv_pvg_lite_set_size_mm(uint32_t width_mm, uint32_t height_mm);

#endif
