#ifndef HENGEVM_PVG_LITE_H
#define HENGEVM_PVG_LITE_H

#include <stdint.h>

#include "gicv3.h"
#include "pvg_display.h"

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
void hv_pvg_metal_submit(HvPvgMetal *m, HvPvgLite *lite, uint32_t channel, uint32_t *command, uint32_t length);
int hv_pvg_metal_snapshot(HvPvgMetal *m, uint8_t *bgra, uint32_t width, uint32_t height);
int hv_pvg_lite_snapshot(HvPvgLite *p, uint8_t *bgra, uint32_t width, uint32_t height);
int hv_pvg_metal_frame(HvPvgMetal *m, const uint8_t **pixels, uint32_t *width, uint32_t *height);
/* NULL destination validates all source pages without allocating or copying. */
int hv_pvg_lite_task_read(HvPvgLite *p, uint32_t task, uint64_t offset, void *to, uint32_t length);
uint32_t hv_pvg_lite_task_page(HvPvgLite *p, uint32_t task, uint64_t offset);
uint8_t *hv_pvg_lite_page(HvPvgLite *p, uint32_t guest_page);
void *hv_pvg_lite_phys(HvPvgLite *p, uint64_t pa, uint64_t length);
uint64_t hv_pvg_lite_task_objects(HvPvgLite *p, uint32_t task);
/* The guest's GPU driver is an older one (macOS 14 seen): no object list command, compact surface descriptions. */
int hv_pvg_lite_old_driver(HvPvgLite *p);
/* A surface's descriptor (1 KB), or NULL if the mapper has none for it. */
const uint8_t *hv_pvg_lite_surface(HvPvgLite *p, uint32_t mapping);
void hv_pvg_metal_unmap(HvPvgMetal *m, uint32_t mapping);
void hv_pvg_metal_cursor_moved(HvPvgMetal *m);
/* Frames go to this CAMetalLayer from now on, drawn by the GPU. Any thread.
   Explicit NULL suspends presentation while retaining the native texture path;
   CPU framebuffer fallback is only for clients that never select native output. */
void hv_pvg_metal_set_layer(HvPvgMetal *m, void *layer);
void hv_pvg_metal_set_display_paused(HvPvgMetal *m, int paused);
void hv_pvg_lite_set_display_paused(HvPvgLite *p, int paused);
/* capture -1 reads, 0 ends bounded capture, 1 starts it. Existing explicit
   GPU timing preference is retained. out: completions/ns/max-ns/unavailable.
   Returns 0 no renderer, 1 renderer/timing off, 2 timing active. No GPU work. */
int hv_pvg_lite_capture_timing(HvPvgLite *p,int capture,uint64_t out[4]);
int hv_pvg_metal_capture_timing(HvPvgMetal *m,int capture,uint64_t out[4]);
/* out: allocated Metal bytes, Metal4 completed buffers, duration ns, max ns.
   0 absent,1 Metal allocation available,2 Metal4 timing also available. Durations
   overlap and include presentation; do not add them to classic time/utilization. */
int hv_pvg_lite_gpu_snapshot(HvPvgLite *p,uint64_t out[4]);
int hv_pvg_metal_gpu_snapshot(HvPvgMetal *m,uint64_t out[4]);
uint64_t hv_pvg_metal_gpu_frames(HvPvgMetal *m);
void hv_pvg_metal_log_metrics(HvPvgMetal *m);
void hv_pvg_lite_log_metrics(HvPvgLite *p);
void hv_pvg_lite_task_pages(HvPvgLite *p, uint32_t task, uint64_t first, uint64_t n, uint32_t *out);
void hv_pvg_lite_set_layer(HvPvgLite *p, void *layer);
uint64_t hv_pvg_lite_gpu_frames(HvPvgLite *p);
void hv_pvg_lite_barrier_stats(HvPvgLite *p, uint64_t out[4]);
/* The display's shared state page, or NULL before the guest named it. */
uint8_t *hv_pvg_lite_display_page(HvPvgLite *p);
uint8_t *hv_pvg_lite_display_page_for_port(HvPvgLite *p, uint32_t port);
/* Host requests are queued onto the Metal worker. */
void hv_pvg_lite_link_connected(HvPvgLite *p, int connected);
void hv_pvg_lite_apply_link_connected(HvPvgLite *p, int connected);
void hv_pvg_metal_link_connected(HvPvgMetal *m, int connected);
void hv_pvg_metal_mirror_refresh(HvPvgMetal *m);
void hv_pvg_lite_mirror_refresh(HvPvgLite *p);
void hv_pvg_metal_link_cursor_moved(HvPvgMetal *m);
void hv_pvg_lite_trim_memory(HvPvgLite *p);
void hv_pvg_metal_trim_memory(HvPvgMetal *m);
void hv_pvg_lite_command(HvPvgLite *p, const uint32_t *command, uint32_t length);
void hv_pvg_lite_complete(HvPvgLite *p, uint32_t channel, uint32_t stamp);

/* Whether the file HV_PVG_TRACE_FILE names exists (tracing asked for while the guest runs): looked at no more than
   every 100 ms, as it was asked for every command (thousands a second, ~0.5% of busy time on the phone). */
int hv_pvg_trace_on(void);

/* The size macOS is told its screen is. Set before the machine starts; default 1920 x 1080. */
void hv_pvg_lite_set_mode(uint32_t width, uint32_t height);
int hv_pvg_lite_set_link_mode(uint32_t width, uint32_t height, uint32_t width_mm, uint32_t height_mm, uint32_t hz);
/* The display's one mode. A scaled resolution chosen in macOS draws smaller surfaces for the same mode. */
void hv_pvg_lite_mode(uint32_t *width, uint32_t *height);
/* Immutable board mode, including snapshot-restored topology. Lifetime lock held. */
int hv_pvg_lite_port_mode(HvPvgLite *p, uint32_t port, HvPvgDisplayMode *out);
void hv_pvg_lite_set_size_mm(uint32_t width_mm, uint32_t height_mm);

/* Instant resume (host/snapshot.c). State blobs: called with out NULL they return the size needed. */
size_t hv_pvg_lite_state(HvPvgLite *p, void *out, size_t cap);
int hv_pvg_lite_set_state(HvPvgLite *p, const void *in, size_t len);
int hv_pvg_lite_quiesce(HvPvgLite *p);
size_t hv_pvg_lite_display_state(HvPvgLite *p, void *out, size_t cap);
int hv_pvg_lite_set_display_state(HvPvgLite *p, const void *in, size_t len);
#include <stdio.h>
void hv_pvg_lite_debug(HvPvgLite *p, FILE *f);
int hv_pvg_metal_quiesce(HvPvgMetal *m);
size_t hv_pvg_metal_display_state(HvPvgMetal *m, void *out, size_t cap);
int hv_pvg_metal_set_display_state(HvPvgMetal *m, const void *in, size_t len);

#endif
