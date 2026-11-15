#include "pvg_link.h"
/* Runs the guest's GPU commands on the host's Metal, on any Apple platform.
   The guest driver serializes Metal calls: an exec names command buffers in a
   task's memory, each a segment holding {tag, size} records, one per call, in
   the formats worked out from the guest driver and listed by the decoders
   below. Objects are named by a number (a ref); the task's object list says
   what each is, and they are made the first time they are used. */

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#endif
#include <stdatomic.h>
#include <os/lock.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <TargetConditionals.h>
#import <IOSurface/IOSurfaceRef.h>
#include <string.h>
#include <math.h>
#include <sys/utsname.h>
#include <sys/sysctl.h>
#include <limits.h>
#include <errno.h>
#include "metallib.h"
#include "trace_gate.h"
#include "frame_pacing.h"
#include "cursor_damage.h"
#include "frame_metrics.h"
#include "gpu_epoch_cache.h"
#include "gpu_binding_cache.h"
#include "gpu_reject_stats.h"
#include "metal4_encoder.h"
#include "metal4_screen.h"
#include "desktop_geometry.h"
#include "planar_registry.h"
#include "pvg_linear_bounds.h"
#include "pipeline_archive_key.h"
#include "metal_library_cache.h"
#include "resource_policy.h"
#include "env_flag.h"
#include "scheduling.h"
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

#include "display_settings.h"
#include "cursor_density.h"
static int cursor_scale_value(HvDisplaySettings settings,const uint8_t *page,uint32_t width) {
    uint16_t mm=0;if(page)memcpy(&mm,page+0x14,sizeof mm);
    return (int)hv_cursor_density_scale(settings.scale,width,mm,hv_display_default_scale);
}
static int cursor_scale(const uint8_t *page,uint32_t width) {
    return cursor_scale_value(hv_display_settings_get(),page,width);
}

#include <mach/mach.h>
#include <stdatomic.h>
#include <mach/vm_map.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pvg_lite.h"
#include "pvg_store_action.h"

#if !TARGET_OS_IPHONE
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

/* Metal's own pipeline serialization, on _MTLDevice. The guest's Metal wrote the data. */
@protocol HvMetalSPI
- (id)newRenderPipelineDescriptorWithSerializedData:(dispatch_data_t)d deserializationContext:(id)c;
- (id)newTileRenderPipelineDescriptorWithSerializedData:(dispatch_data_t)d deserializationContext:(id)c;
- (id)newComputePipelineDescriptorWithSerializedData:(dispatch_data_t)d deserializationContext:(id)c;
@end

enum { OBJ_BUFFER = 1, OBJ_TEXTURE = 2, OBJ_FUNCTION = 6, OBJ_SERIALIZED = 7, OBJ_LINEAR_TEXTURE = 8, OBJ_MAPPED_TEXTURE = 0xb };

/* What is known about a made object, so a reused ref is noticed. */
@interface HvObject : NSObject {
@public
    id object;
    uint32_t entry[3];
    /* A buffer's guest pages, mapped contiguously. */
    uint8_t *mapped;
    BOOL mapping_in_buffer; /* the buffer over them frees them */
    BOOL plain_buffer; /* the object is that buffer */
    uint64_t refresh_epoch; uint32_t refresh_task;
    uint32_t generation; /* a new mapping since: what was made from it is out of date */
    HvObject *follows; /* made from this one's buffer */
    uint32_t follows_generation;
    uint64_t length;
    uint32_t vpage;
    uint32_t *pages;
    /* A texture's layout in guest memory. */
    uint32_t tex_mips, tex_slices;
    uint64_t tex_base, tex_stride;
    uint8_t tex_block_h;
    uint8_t *tex_layout; /* the mip table, 36 bytes each */
    BOOL guest_backed;
    uint32_t retries; /* a mapped texture made before its surface was described: tried again on later uses */
    uint8_t described[0x30]; /* a surface: the older driver's compact description it was made from */
    uint64_t on_mapping; /* a mapped texture: the surface id it is over */
    /* A surface: */
    HvObject *surface;
    uint64_t row;
    uint32_t first;
    uint32_t surface_w, surface_h, fourcc; /* its own, whatever views the guest makes of it */
    id<MTLTexture> scanout; /* the same pixels, as the display reads them */
    /* Multi-plane surfaces cannot sit on a buffer: a real IOSurface, kept up to date from the guest's pages. */
    IOSurfaceRef iosurface;
    uint64_t alloc, content_hash, sync_epoch;
    /* Source layout for a multi-plane video surface. */
    uint32_t plane_count;
    uint64_t plane_from[4], plane_row[4], plane_h[4];
    /* Each plane's sampled guest bytes when last copied: only the planes the guest changed are copied, so a CPU
       write to one plane (a decoder refilling luma) does not wipe what the GPU drew into another (chroma, alpha). */
    uint64_t plane_hash[4];
    /* For a host IOSurface shared by several mappings (see planar): the same four hashes, kept once for all of
       them, since they describe what the one host surface holds. */
    NSMutableData *shared_hashes;
    /* A heap: private memory, a buffer over all of it. */
    id<MTLBuffer> heap_whole;
    /* A heap's or a private texture's copy in guest memory, and which side has the newest bytes. */
    id<MTLBuffer> guest_copy;
    BOOL host_valid, guest_stale;
    /* What this one is made from, kept for as long as it lives. */
    HvObject *parent;
    /* A multi-plane surface's key in the replay's planar table, while it counts as one of its users. */
    NSData *planar_key;
    HvPlanarEntry *planar_entry;
}
@end

@implementation HvObject
- (void)dealloc {
    if (mapped && !mapping_in_buffer) vm_deallocate(mach_task_self(), (vm_address_t)mapped, (length + 0x3fff) & ~0x3fffull);
    if (iosurface) CFRelease(iosurface);
    free(pages);
    free(tex_layout);
}
@end

@class HvContext;

/* The registration lock never crosses encoding, callbacks or network operations. */
static os_unfair_lock link_handler_lock = OS_UNFAIR_LOCK_INIT;
static HvPvgLinkFrameHandler link_handler, primary_handler;
void hv_pvg_link_set_primary_frame_handler(HvPvgLinkFrameHandler handler) {
    os_unfair_lock_lock(&link_handler_lock);primary_handler=[handler copy];os_unfair_lock_unlock(&link_handler_lock);
}
static HvPvgLinkFrameHandler primary_frame_handler(void) {
    os_unfair_lock_lock(&link_handler_lock);HvPvgLinkFrameHandler handler=primary_handler;os_unfair_lock_unlock(&link_handler_lock);return handler;
}
void hv_pvg_link_set_frame_handler(HvPvgLinkFrameHandler handler) {
    os_unfair_lock_lock(&link_handler_lock);
    link_handler = [handler copy];
    os_unfair_lock_unlock(&link_handler_lock);
}
static HvPvgLinkFrameHandler link_frame_handler(void) {
    os_unfair_lock_lock(&link_handler_lock);
    HvPvgLinkFrameHandler handler = link_handler;
    os_unfair_lock_unlock(&link_handler_lock);
    return handler;
}
@interface HvReplay : NSObject {
@public
    HvPvgLite *lite;
    _Atomic int mirror_queued;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    dispatch_queue_t worker;
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, HvObject *> *> *tasks;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *mapped_textures;
    NSMutableDictionary<NSNumber *, HvObject *> *surfaces;
    /* Multi-plane surfaces' host IOSurfaces by the guest memory they stand for: each process maps a surface
       under its own mapping id, and what one draws (macOS 27's WebKit draws pages into b3a8 tiles in its GPU
       process) has to be what another reads (WindowServer). */
    NSMutableDictionary<NSData *, HvPlanarLink *> *planar;
    NSMutableSet<NSString *> *complaints;
    uint64_t execs, draws, heap_bytes, synced, remaps;
    _Atomic uint64_t failed;
    HvMetalLibraryCache *library_cache; /* serial GPU worker only; exact binary keys */
    dispatch_source_t memory_pressure_source;
    int memory_pressure;
    double cache_budget_deadline;
    double cache_warning_until; /* UIKit warnings have no paired 'normal' event */
    uint64_t cache_warnings;
    uint64_t logged_budget_bytes;
    unsigned logged_budget_entries;
    int logged_budget_pressure;
    BOOL diagnostics_enabled;
    double library_load_seconds, library_load_worst;
    uint64_t surface_checks, surface_checks_avoided, planar_creations, planar_reuses;
    BOOL batch_cache, gpu_timing, resource_tally;
    atomic_int capture_timing;
    uint64_t command_epoch, current_epoch, object_hits, object_reads, page_checks, page_hits;
    struct HvGpuEpochKey object_keys[HV_GPU_EPOCH_SLOTS];
    HvObject *object_values[HV_GPU_EPOCH_SLOTS];
    uint64_t pipeline_builds;
    double pipeline_seconds, pipeline_worst_seconds;
    /* Work the GPU has not finished. Stamps are given back in the order they came: the
       GPU's completion handlers run in the order of commit. */
    _Atomic int inflight;
    _Atomic int stopping;
    dispatch_group_t completions;
    id<MTLCommandBuffer> last_cb;
    id metal4; /* populated only behind the OS/GPU capability gate */
    id metal4_screen;
    BOOL desktop_fx;
    atomic_uint display_fx_limit;
    uint64_t screen_image_epoch;
    id pipeline_bundle;
    os_unfair_lock submission_lock;
    uint64_t metal4_replayed,metal4_fallback,metal4_unsupported,metal4_encoder_rejected,metal4_job_missed,metal4_bridge_rejected;
    uint64_t metal4_warming;
    uint64_t metal4_metadata,metal4_reject_reasons[HV_GPU_REASON_COUNT];
    HvGpuReject metal4_last_reject;
    HvGpuRejectStats metal4_reject_stats;
    _Atomic uint64_t metal4_guest_completed,metal4_guest_failed;
    _Atomic unsigned presentation_inflight;
    _Atomic uint64_t presentation_backpressure;
    double encode_time, gpu_wait_time, capture_log_next;
    _Atomic uint64_t gpu_completed, gpu_duration_ns, gpu_max_ns, gpu_timing_missing;
    _Atomic uint64_t gpu_queue_samples,gpu_queue_ns,gpu_queue_max_ns,gpu_completion_ns,gpu_inflight_peak;
    HvFramePacing frame_pacing;
    BOOL pacing_pending;
    int pacing_fps;
    BOOL pacing_policy_logged;

    BOOL pipeline_set; /* in the open encoder */
    HvBindingCache bindings; /* only used by the serial replay worker */
    BOOL tess_factors; /* so is a tessellation factor buffer */
    uint32_t pre_raster_samples, pre_imageblock, pre_threadgroup, pre_tile_w, pre_tile_h; /* for the next pass */
    BOOL tracing; /* HV_PVG_TRACE_FILE exists: say what each exec draws */
    HvTraceGate trace_gate;
    /* The newest frame, BGRA, for hv_pvg_metal_frame, and the same without the pointer on it. */
    uint8_t *frame, *base;
    NSMutableArray<NSValue *> *retired_frames;
    uint32_t frame_w, frame_h;
    /* The pointer: macOS sends it apart from the screen, for the display hardware to overlay. */
    uint8_t *cursor;
    uint32_t cursor_w, cursor_h, cursor_stride;
    int cursor_hot_x, cursor_hot_y;
    BOOL cursor_shown;
    int drawn_x, drawn_y, drawn_w, drawn_h; /* where it is on the frame now */
    double last_capture;
    /* A frame that came too soon after the last: shown shortly, for it may be the last for a long while. */
    uint64_t late_mapping;
    BOOL late, late_queued;
    uint64_t frames, frames_shot;
    /* Showing frames with the GPU: a layer the app gave us. No copies, no conversion on a CPU. */
    CAMetalLayer *layer; /* screen_lock protects the target and its generation */
    BOOL native_output_selected; /* explicit nil suspends; never re-enable CPU readback */
    BOOL display_driven, display_quiesced, display_scene_active, display_arm_pending;
    BOOL display_pulse_active;
    uint32_t display_prepared_w,display_prepared_h;
#if TARGET_OS_IPHONE
    CAMetalDisplayLink *display_link;
    id display_delegate, scene_activate_observer, scene_deactivate_observer;
    __weak CAMetalLayer *display_link_layer;
    uint64_t display_link_generation;
    id<CAMetalDrawable> display_drawable;
#endif
    uint64_t layer_generation;
    __weak CAMetalLayer *prepared_layer; /* presenter only: each target needs its own setup */
    id<MTLRenderPipelineState> screen_pipe, linear_pipe, cursor_pipe;
    id<MTLFunction> stand_in; /* computeStandIn */
    /* Compiled pipelines kept across sessions (pipelineState:descriptor:). iOS clears its own shader cache between
       launches, so without this every boot compiles each of macOS's pipelines again, about half a second apiece. */
    /* Single-pipeline files avoid backend last-function-wins serialization.
       Index files lazily; retain at most16 loaded archive handles and64 pending. */
    NSMutableDictionary<NSString *,NSMutableArray<NSMutableDictionary *> *> *archive_paths;
    NSMutableArray<NSMutableDictionary *> *archive_order;
    NSMutableDictionary<NSString *,id<MTLBinaryArchive>> *archive_handles;
    NSMutableArray<NSString *> *archive_lru;
    int archive_budget_pressure;
    NSMutableArray<NSDictionary *> *archive_pending;
    NSURL *archive_dir;
    NSString *archive_prefix;
    int archive_next; /* the next file's number */
    unsigned long long archive_bytes;
    BOOL archive_open_attempted, archive_pressure_suspended;
    dispatch_source_t archive_save_timer; /* one debounced active-only save, worker-owned */
    uint64_t pipes_hit, pipes_compiled, pipes_unsaved, pipes_unsaveable;
    double compile_ms, hit_ms;

    id<MTLTexture> cursor_tex;
    id<MTLSamplerState> screen_sampler, cursor_sampler;
    uint64_t on_screen; /* the mapping showing */
    uint64_t link_mapping;
    id<MTLTexture> link_cursor;
    uint32_t link_cw, link_ch, link_hx, link_hy;
    BOOL link_cursor_shown;
    _Atomic int link_cursor_queued;
    _Atomic uint64_t gpu_frames;
    atomic_int frame_metrics_enabled;
    BOOL frame_metrics_requested;
    uint64_t frame_metrics_epoch;
    os_unfair_lock frame_metrics_lock;
    struct HvFrameMetrics frame_metrics;
    dispatch_queue_t presenter;
    os_unfair_lock screen_lock; /* what to show, and the pointer as the presenter reads it */
    id<MTLTexture> screen_tex;
    BOOL screen_half, screen_dirty, presenter_running;
    BOOL drawable_retry_pending;
    double drawable_retry_cooldown; /* fresh work coalesces one wake at its expiry */
    uint64_t screen_requests; /* fresh frames/cursor changes, not automatic retries */
    uint64_t cursor_revision;
    HvCursorDamage cursor_damage;
    id settings_observer;
    double drawable_retry_deadline; /* at most two seconds of retrying an unavailable target */
    uint32_t screen_w, screen_h;
    id<MTLBuffer> test_readback; /* HV_PVG_GPU_TEST: the drawable's pixels for screenshots */
    id<MTLBuffer> readback;
    const char *shot;
    unsigned shots;
    dispatch_source_t shot_timer;
}
- (void)complain:(NSString *)what;
- (HvObject *)object:(uint32_t)ref task:(uint32_t)task;
- (void)drawCursor;
- (BOOL)usesNativePresentation;
- (void)kickPresenter:(BOOL)fresh;
- (void)present:(uint64_t)mapping;
- (void)screenChanged;
- (void)sendPrimaryMirror;
- (void)schedulePrimaryMirror;
- (void)sendLinkMapping:(uint64_t)mapping;
- (void)refreshCacheBudget;
- (void)preparePlanar:(HvObject *)surface descriptor:(const uint8_t *)desc compact:(BOOL)compact identity:(NSData *)identity;
- (void)openArchive;
- (void)saveArchive;
- (void)scheduleArchiveSave;
- (void)dropArchiveMemory;
- (void)forgetArchiveFile:(NSMutableDictionary *)entry;
- (id<MTLBinaryArchive>)loadArchiveFile:(NSMutableDictionary *)entry;
- (BOOL)prepareScreenForLayer:(CAMetalLayer *)target;
#if TARGET_OS_IPHONE
- (void)requestDisplayPulse;
- (void)displayPulse:(CAMetalDisplayLink *)link update:(CAMetalDisplayLinkUpdate *)update;
#endif
@end

#if TARGET_OS_IPHONE
@interface HvDisplayPulse : NSObject <CAMetalDisplayLinkDelegate>
@property(nonatomic, weak) HvReplay *owner;
@end
@implementation HvDisplayPulse
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    HvReplay *owner=self.owner;
    if(owner)[owner displayPulse:link update:update];else link.paused=YES;
}
@end
#endif

/* What Metal asks while it reads a serialized pipeline. */
@interface HvContext : NSObject {
@public
    __unsafe_unretained HvReplay *replay;
    uint32_t task;
    NSString *failure;
    id standIn; /* what a failed function lookup returns: nil, except for compute pipelines (makeSerialized) */
}
@end

/* Bytes a pixel takes in the uncompressed formats a surface gets viewed as; 0 for one not listed. */
static NSUInteger pixel_bytes(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Unorm_sRGB: case MTLPixelFormatR8Snorm:
    case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: return 1;
    case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float:
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Unorm_sRGB: case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
    case MTLPixelFormatB5G6R5Unorm: case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatABGR4Unorm: case MTLPixelFormatBGR5A1Unorm: return 2;
    case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatR32Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRG16Snorm:
    case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRG16Float: case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatRGBA8Snorm: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB9E5Float:
    case MTLPixelFormatBGR10A2Unorm: case MTLPixelFormatBGR10_XR: case MTLPixelFormatBGR10_XR_sRGB: return 4;
    case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm:
    case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float: case MTLPixelFormatBGRA10_XR: case MTLPixelFormatBGRA10_XR_sRGB: return 8;
    case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float: return 16;
    default: return 0;
    }
}

/* Metal aborts the app, rather than failing, on a linear texture whose rows don't hold its width or don't fit the buffer.
   A view the guest makes in another format, or a surface read with the wrong description, can ask for one. */
static BOOL linear_texture_fits(id<MTLDevice> device, MTLTextureDescriptor *t, uint64_t offset, uint64_t row, NSUInteger length) {
    NSUInteger bpp = pixel_bytes(t.pixelFormat);
    if (!bpp) return YES; /* not checked: as before */
    NSUInteger align = [device minimumLinearTextureAlignmentForPixelFormat:t.pixelFormat];
    BOOL ok = hv_pvg_linear_bounds(t.width,t.height,bpp,offset,row,length,align);
    if (!ok) {
        static int told;
        if (told++ < 8) fprintf(stderr, "hengevm: pvg-metal: a %lux%lu format %lu texture can't sit on rows of %llu bytes at %llu in %lu: left empty\n",
                                (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, row, offset, (unsigned long)length);
    }
    return ok;
}

static double now_seconds(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) * 1e-9;
}

/* How the half-float display surface is shown. WindowServer writes DISPLAY-ENCODED values there (extended sRGB: the guest's gray 128 is
   0.502, measured with the colour probe), so mode 0 passes them through. Mode 1 treats them as LINEAR light and applies the sRGB encode,
   which is what this code did before (and was only right for a linear display profile such as ACES CG Linear: with every other profile
   it encodes twice and the screen looks pale). HV_PVG_HALF=linear selects mode 1 at start; with the colour probe on, a file named
   mode-linear or mode-encoded in its folder switches it while running. */
static _Atomic int hv_half_mode = -1;
static int hv_half_mode_get(void) {
    int m = atomic_load(&hv_half_mode);
    if (m < 0) {
        const char *e = getenv("HV_PVG_HALF");
        m = e && !strcmp(e, "linear") ? 1 : 0;
        atomic_store(&hv_half_mode, m);
    }
    return m;
}
static float hv_half_shown(float v, int mode) { /* what the screen shows for a half-float component */
    v = v < 0 ? 0 : v > 1 ? 1 : v;
    return mode == 1 ? (v <= 0.0031308f ? v * 12.92f : 1.055f * powf(v, 1.0f / 2.4f) - 0.055f) : v;
}

#include "pvg_colorprobe.h" /* HV_COLOR_PROBE: what the display is told and shown, for chasing colour problems */

/* A contiguous view of a task's guest pages; holes are left as zero pages. */
/* A range of task memory at one address, page by page. Metal pins a buffer's
   pages when the buffer is made, so a mapping never changes under a buffer: when
   the guest's pages change there is a new mapping and a new buffer. (A GPU still
   writing to pages the guest has freed and used again would corrupt its memory.) */
static BOOL map_pages(HvReplay *r, uint32_t task, HvObject *o) {
    uint64_t n = (o->length + 0x3fff) >> 14;
    vm_address_t base = 0;
    if (vm_allocate(mach_task_self(), &base, n << 14, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return NO;
    uint32_t *pages = calloc(n, 4);
    hv_pvg_lite_task_pages(r->lite, task, o->vpage, n, pages);
    for (uint64_t i = 0; i < n; i++) {
        uint8_t *src = pages[i] ? hv_pvg_lite_page(r->lite, pages[i]) : NULL;
        if (!src) {
            pages[i] = 0;
            continue;
        }
        vm_address_t to = base + (i << 14);
        vm_prot_t cur, max;
        kern_return_t kr = vm_remap(mach_task_self(), &to, 0x4000, 0, VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)src, FALSE, &cur, &max, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "hengevm: pvg-metal: vm_remap failed: %d\n", kr);
            vm_deallocate(mach_task_self(), base, n << 14);
            free(pages);
            return NO;
        }
    }
    free(o->pages);
    o->pages = pages;
    o->mapped = (uint8_t *)base;
    return YES;
}

/* A buffer over the mapping, that frees it when the last user is done. */
static id<MTLBuffer> buffer_over_mapping(HvReplay *r, HvObject *o) {
    uint8_t *base = o->mapped;
    NSUInteger bytes = (NSUInteger)((o->length + 0x3fff) & ~0x3fffull);
    id<MTLBuffer> b = [r->device newBufferWithBytesNoCopy:base length:bytes options:MTLResourceStorageModeShared
                                              deallocator:^(void *at, NSUInteger size) { vm_deallocate(mach_task_self(), (vm_address_t)at, size); }];
    if (b) o->mapping_in_buffer = YES;
    return b;
}

/* The guest's table for this range against what is mapped: a change means a new mapping. */
static void refresh_pages(HvReplay *r, uint32_t task, HvObject *o) {
    if (!o->mapped) return;
    if (r->batch_cache && r->current_epoch && o->refresh_epoch == r->current_epoch && o->refresh_task == task) { r->page_hits++; return; }
    if (r->batch_cache) r->page_checks++;
    uint64_t n = (o->length + 0x3fff) >> 14;
    uint32_t stack[256];
    uint32_t *now = n <= 256 ? stack : malloc(n * 4);
    hv_pvg_lite_task_pages(r->lite, task, o->vpage, n, now);
    BOOL same = memcmp(now, o->pages, n * 4) == 0;
    if (now != stack) free(now);
    if (same) { o->refresh_epoch = r->current_epoch; o->refresh_task = task; return; }
    uint8_t *old = o->mapped;
    BOOL old_in_buffer = o->mapping_in_buffer;
    if (!map_pages(r, task, o)) return;
    if (!old_in_buffer) vm_deallocate(mach_task_self(), (vm_address_t)old, n << 14);
    o->mapping_in_buffer = NO;
    o->generation++;
    o->guest_copy = nil;
    if (o->plain_buffer) o->object = buffer_over_mapping(r, o);
    r->remaps++;
    o->refresh_epoch = r->current_epoch; o->refresh_task = task;
}

static void set_framebuffer_only(MTLTextureDescriptor *t, BOOL on) {
    SEL sel = sel_registerName("setFramebufferOnly:");
    if ([t respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(t, sel, on);
}

/* What Apple's host takes from both serialized forms: flags (framebuffer only bit 4, GPU
   optimized bit 6) and resource options, of which iOS has no managed memory. */
static void descriptor_common(MTLTextureDescriptor *t, uint8_t flags, uint16_t options) {
    set_framebuffer_only(t, (flags >> 4) & 1);
    t.allowGPUOptimizedContents = (flags >> 6) & 1;
    MTLResourceOptions o = options & 0x3ff;
#if TARGET_OS_IPHONE
    if ((o & 0xf0) == 0x10) o = (o & ~(MTLResourceOptions)0xf0) | MTLResourceStorageModeShared;
#endif
    t.resourceOptions = o;
}

/* Metal aborts the whole app on a swizzle channel outside 0...5 (seen as 193 when a surface's description was
   read short, see makeMappedTexture), so an unknown one falls back to the identity, logged a few times. */
static MTLTextureSwizzleChannels safe_swizzle(const uint8_t *sw, const uint8_t *desc, size_t desc_len, const char *what) {
    if (!(sw[0] | sw[1] | sw[2] | sw[3])) /* all Zero: never meant, it would draw nothing; an unread field */
        return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    for (int i = 0; i < 4; i++) {
        if (sw[i] > MTLTextureSwizzleAlpha) {
            static int told;
            if (told++ < 3) {
                fprintf(stderr, "hengevm: pvg-metal: %s swizzle %u %u %u %u is not a Metal swizzle; using RGBA. desc:", what, sw[0], sw[1], sw[2], sw[3]);
                for (size_t j = 0; j < desc_len; j++) fprintf(stderr, " %02x", desc[j]);
                fputc('\n', stderr);
            }
            return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
        }
    }
    return MTLTextureSwizzleChannelsMake(sw[0], sw[1], sw[2], sw[3]);
}

/* The two serialized forms of a texture description. */
static MTLTextureDescriptor *descriptor_v1(const uint8_t *d) {
    MTLTextureDescriptor *t = [MTLTextureDescriptor new];
    t.textureType = (MTLTextureType)(d[0] & 0xf);
    t.usage = d[1];
    t.pixelFormat = (MTLPixelFormat)(d[2] | d[3] << 8);
    t.width = *(const uint32_t *)(d + 4);
    t.height = *(const uint32_t *)(d + 8);
    t.depth = *(const uint32_t *)(d + 12);
    t.mipmapLevelCount = *(const uint16_t *)(d + 16);
    t.sampleCount = *(const uint16_t *)(d + 18);
    t.arrayLength = *(const uint16_t *)(d + 20);
    descriptor_common(t, d[0], *(const uint16_t *)(d + 22));
    return t;
}

static MTLTextureDescriptor *descriptor_v2(const uint8_t *d) {
    MTLTextureDescriptor *t = [MTLTextureDescriptor new];
    uint32_t usage, w, h, depth;
    uint16_t mips, samples, array, options;
    memcpy(&usage, d + 3, 4), memcpy(&w, d + 7, 4), memcpy(&h, d + 11, 4), memcpy(&depth, d + 15, 4);
    memcpy(&mips, d + 19, 2), memcpy(&samples, d + 21, 2), memcpy(&array, d + 23, 2), memcpy(&options, d + 25, 2);
    t.textureType = (MTLTextureType)(d[0] & 0xf);
    t.pixelFormat = (MTLPixelFormat)(d[1] | d[2] << 8);
    t.usage = usage;
    t.width = w, t.height = h, t.depth = depth;
    t.mipmapLevelCount = mips, t.sampleCount = samples, t.arrayLength = array;
    descriptor_common(t, d[0], options);
    t.swizzle = safe_swizzle(d + 0x23, d, 0x27, "texture");
    if (t.usage & MTLTextureUsageRenderTarget) /* Metal aborts on a swizzled render target */
        t.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    return t;
}

@implementation HvContext
- (void)resetFailureState { failure = nil; }
- (BOOL)hadLookupFailure { return failure != nil; }
- (NSString *)firstFailureReason { return failure; }
- (id)functionWithFunctionRef:(unsigned long long)ref {
    if (!ref) {
        if (standIn && !failure) failure = @"function ref 0 in a compute pipeline";
        return standIn;
    }
    HvObject *o = [replay object:(uint32_t)ref task:task];
    if (!o || !o->object || (o->entry[0] & 0xff) != OBJ_FUNCTION) {
        if (!failure) failure = [NSString stringWithFormat:@"missing or non-function object %llu", ref];
        return standIn;
    }
    return o->object;
}
@end

@implementation HvReplay
- (void)refreshCacheBudget {
    uint64_t available = UINT64_MAX;
#if TARGET_OS_IPHONE
    available = os_proc_available_memory();
#endif
    int pressure = memory_pressure;
    /* One existing worker owns both pressure sources. Hold the reduced budget
       after UIKit warnings; recover on later misses without a polling timer. */
    if (now_seconds() < cache_warning_until && pressure < 1) pressure = 1;
    if (pressure >= 2 || available < (512ull << 20)) {
        [self dropArchiveMemory]; archive_pressure_suspended=YES;
    } else {
        if (archive_pressure_suspended) { archive_open_attempted=NO; archive_pressure_suspended=NO; }
        if (pressure && !archive_budget_pressure) {
            // A moderate warning is not a reason to throw away compiled PSOs
            // or suspend on-disk reuse for 30 seconds during app/game startup.
            // Flush the bounded pending batch once; release loaded handles.
            [self saveArchive];
            [archive_handles removeAllObjects];[archive_lru removeAllObjects];
        }
    }
    archive_budget_pressure=pressure;
    if(@available(macOS 26.0,iOS 26.0,*))[metal4 setArchiveAdmission:!archive_pressure_suspended];
    unsigned fxLimit=hv_desktop_fx_limit(available,pressure);
    unsigned previousFX=atomic_exchange(&display_fx_limit,fxLimit);
    if(desktop_fx && previousFX!=fxLimit){
        fprintf(stderr,"desktop-metalfx-admission: enabled=%d leases=%u pressure=%d process_headroom=%llu UIKit_hold=%d (moderate pressure trims spare leases; critical fallback preserves output geometry; guest RAM unchanged)\n",fxLimit!=0,fxLimit,pressure,(unsigned long long)available,now_seconds()<cache_warning_until);
        dispatch_async(presenter,^{if(@available(macOS 26.0,iOS 26.0,*))[self->metal4_screen setFXCacheLimit:fxLimit];});
    }
    HvResourceBudget budget = hv_resource_budget_profile(available, pressure, hv_host_is_m4_16gb());
    [library_cache setAdmissionBytes:hv_env_flag("HV_GPU_LIBRARY_CACHE_OFF") ? 0 : (NSUInteger)budget.library_bytes
                            entries:budget.library_entries];
    if(logged_budget_entries != budget.library_entries || logged_budget_bytes != budget.library_bytes || logged_budget_pressure != pressure) {
        fprintf(stderr,"gpu-cache-budget: entries=%u bytes=%llu pressure=%d process_headroom=%llu UIKit_hold=%d (process allowance is not system free RAM; no live guest RAM change)\n",budget.library_entries,(unsigned long long)budget.library_bytes,pressure,(unsigned long long)available,now_seconds()<cache_warning_until);
        logged_budget_entries=budget.library_entries;logged_budget_bytes=budget.library_bytes;logged_budget_pressure=pressure;
    }
    cache_budget_deadline = now_seconds() + 1;
}

- (void)complain:(NSString *)what {
    if ([complaints containsObject:what]) return;
    [complaints addObject:what];
    fprintf(stderr, "hengevm: pvg-metal: %s\n", what.UTF8String);
}

/* A kernel that does nothing. Metal's deserializer aborts the whole app when a compute pipeline's function is nil, which
   happens when this OS cannot load the library macOS sent ("This library format is not supported on this platform", seen on
   iPadOS 17 with macOS 15). The lookup has failed either way, so makeSerialized drops the pipeline: a missing effect, not a
   crash. */
- (id)computeStandIn {
    if (!stand_in) {
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:@"#include <metal_stdlib>\nkernel void hv_stand_in() {}\n" options:nil error:&err];
        stand_in = [lib newFunctionWithName:@"hv_stand_in"];
        if (!stand_in) [self complain:[NSString stringWithFormat:@"stand-in kernel: %@", err.localizedDescription]];
    }
    return stand_in;
}

- (id)makeFunction:(uint64_t)at task:(uint32_t)task {
    if (getenv("HV_PVG_FAIL_LIBS")) { /* testing: every library refused, as an OS that cannot load them does */
        [self complain:@"library: refused (HV_PVG_FAIL_LIBS)"];
        return nil;
    }
    struct __attribute__((packed)) { uint64_t off; uint32_t len; uint32_t tag, size; } h;
    if (hv_pvg_lite_task_read(lite, task, at, &h, sizeof h)) return nil;
    if (h.tag != 15) { [self complain:@"function record tag is not 15"]; return nil; }
    /* Reject malformed/unmapped blobs before a guest-controlled length can
       allocate a huge host buffer. Recheck during copy if guest tables change. */
    if (!h.len || hv_pvg_lite_task_read(lite, task, h.off, NULL, h.len)) return nil;
    NSMutableData *lib = [NSMutableData dataWithLength:h.len];
    if (!lib) return nil;
    if (hv_pvg_lite_task_read(lite, task, h.off, lib.mutableBytes, h.len)) return nil;
    __block NSError *err = nil;
    id<MTLFunction> function = [library_cache firstFunctionForData:lib loader:^id<MTLLibrary> {
        double begin = now_seconds();
        /* Miss-only, at most once/second under active compilation. No idle
           timer; caches recover admission when process headroom recovers. */
        if (begin >= self->cache_budget_deadline) [self refreshCacheBudget];
        /* Keep upstream iOS 17 compatibility in the contribution series.
           Modern iOS/macOS load the original bytes; never rewrite their AIR. */
        BOOL legacy = NO;
#if TARGET_OS_IPHONE
        if (@available(iOS 18.0, *)) {} else { legacy = YES; }
#endif
        id<MTLLibrary> result = nil;
        int first = 0, last = 0;
        if (legacy && !getenv("HV_PVG_NO_RELABEL")) {
            const char *option = getenv("HV_PVG_RELABEL");
            int stage = option ? atoi(option) : 0;
            first = stage >= 1 && stage <= 3 ? stage : 0;
            last = first == 3 ? 3 : 2;
        }
        for (int stage = first; stage <= last && !result; stage = stage ? stage + 1 : 2) {
            NSMutableData *candidate = lib;
            if (stage) {
                candidate = [lib mutableCopy];
                const char *why = NULL;
                if (hv_metallib_relabel(candidate.mutableBytes, candidate.length, stage, &why) <= 0) continue;
                if (why) [self complain:[NSString stringWithFormat:@"legacy library relabel: %s", why]];
            }
            dispatch_data_t data = dispatch_data_create(candidate.bytes, candidate.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            result = [self->device newLibraryWithData:data error:&err];
        }
        if (result && result.functionNames.count != 1) {
            [self complain:@"guest function library must contain exactly one function"];
            result = nil;
        }
        double seconds = now_seconds() - begin;
        self->library_load_seconds += seconds;
        if (seconds > self->library_load_worst) self->library_load_worst = seconds;
        return result;
    }];
    if (!function) {
        [self complain:[NSString stringWithFormat:@"library: %@", err.localizedDescription]];
        return nil;
    }
    const char *archive_option=getenv("HV_PVG_ARCHIVE");
    if(!archive_option || strcmp(archive_option,"0"))hv_archive_associate_function(function,lib);
    {   /* m4 fork: while tracing, keep each library macOS sends, to read its shaders on a Mac. Also, unless
           HV_SHADER_DUMP=0, the first 48 that had to be relabelled (Documents/shaders, as sent): what an OS that
           refuses them was sent, for relabelling to be checked against on a Mac. */
        const char *tf = getenv("HV_PVG_TRACE_FILE"), *sd = getenv("HV_SHADER_DUMP");
        int keep = sd && atoi(sd) != 0;
        if (tf && keep) {
            NSString *dir = [[[NSString stringWithUTF8String:tf] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shaders"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *name = [NSString stringWithFormat:@"%@-%llx.metallib", function.name ?: @"lib", (unsigned long long)at];
            [lib writeToFile:[dir stringByAppendingPathComponent:name] atomically:NO];
        }
    }
    return function;
}

- (id)pipelineDescriptor:(uint32_t)tag data:(NSData *)all task:(uint32_t)task {
    const uint32_t *w = all.bytes;
    id<HvMetalSPI> spi = (id)device;
    HvContext *ctx = [HvContext new];
    ctx->replay = self, ctx->task = task;
    if (tag == 0xb) ctx->standIn = [self computeStandIn];
    dispatch_data_t data = dispatch_data_create((const uint8_t *)all.bytes + 16, w[3], NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id descriptor = tag == 0xe ? [spi newRenderPipelineDescriptorWithSerializedData:data deserializationContext:ctx]
                  : tag == 0x33 ? [spi newTileRenderPipelineDescriptorWithSerializedData:data deserializationContext:ctx]
                                : [spi newComputePipelineDescriptorWithSerializedData:data deserializationContext:ctx];
    if (!descriptor || ctx->failure) {
        [self complain:[NSString stringWithFormat:@"%@ descriptor %u: %@", tag == 0xb ? @"compute" : @"pipeline", tag, ctx->failure]];
        return nil;
    }
    id function = tag == 0xe ? [(MTLRenderPipelineDescriptor *)descriptor vertexFunction]
                : tag == 0x33 ? [(MTLTileRenderPipelineDescriptor *)descriptor tileFunction]
                              : [(MTLComputePipelineDescriptor *)descriptor computeFunction];
    if (!function) {
        [self complain:[NSString stringWithFormat:@"pipeline %u without its %s function", tag, tag == 0xe ? "vertex" : tag == 0x33 ? "tile" : "compute"]];
        return nil;
    }
    return descriptor;
}

/* Saved pipelines. iOS empties its own Metal shader cache between launches, so every boot compiled each of macOS's
   pipelines again (420 to 550 ms apiece on the Duo). They are kept in binary archives instead, in Application Support
   (iOS purges Caches), named for the OS build and GPU: a compiled pipeline is only good for the compiler and GPU that
   made it, and archives from another build are removed rather than loaded.
   Each save writes a new file holding only the pipelines added since the last save, and every file is loaded at start:
   on the Duo, serializing an archive that was loaded from a file wrote only what had been added to it, so one file
   rewritten in place kept losing the earlier boots' pipelines. A file holds one pipeline: native tests also found
   last-function-wins behavior when several pipelines shared a container. One bounded index retains at most2048
   files/128MiB, only16 lazily opened handles and64 pending additions. Old disposable files are evicted on demand.
   HV_PVG_ARCHIVE=0: none (for A/B); HV_PVG_ARCHIVE=reset: start again. HV_PVG_ARCHIVE_MB: the cap (default 128 MiB, maximum 512). */
static unsigned long long archive_cap(void) {
    const char *mb = getenv("HV_PVG_ARCHIVE_MB");
    return (mb && atoi(mb) > 0 ? MIN((unsigned long long)atoi(mb),512ull) : 128ull) << 20;
}

- (id<MTLBinaryArchive>)emptyArchive {
    NSError *err = nil;
    id<MTLBinaryArchive> a = [device newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&err];
    if (!a) fprintf(stderr, "hengevm: pvg-metal: saved pipelines unavailable: %s\n", err.localizedDescription.UTF8String ?: "?");
    return a;
}

- (void)forgetArchiveFile:(NSMutableDictionary *)entry {
    NSURL *url=entry[@"url"];NSString *name=url.lastPathComponent,*key=entry[@"key"];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    archive_bytes-=MIN(archive_bytes,[entry[@"bytes"]unsignedLongLongValue]);
    [archive_paths[key]removeObjectIdenticalTo:entry];if(!archive_paths[key].count)[archive_paths removeObjectForKey:key];
    [archive_order removeObjectIdenticalTo:entry];[archive_handles removeObjectForKey:name];[archive_lru removeObject:name];
}
- (id<MTLBinaryArchive>)loadArchiveFile:(NSMutableDictionary *)entry {
    NSURL *url=entry[@"url"];NSString *name=url.lastPathComponent;
    id<MTLBinaryArchive> a=archive_handles[name];
    if(!a){MTLBinaryArchiveDescriptor *d=[MTLBinaryArchiveDescriptor new];d.url=url;NSError *error=nil;
        a=[device newBinaryArchiveWithDescriptor:d error:&error];
        if(!a){[self complain:[NSString stringWithFormat:@"saved pipeline unreadable: %@",error.localizedDescription]];[self forgetArchiveFile:entry];return nil;}
        while(archive_lru.count>=(archive_budget_pressure ? 4u : 16u)){NSString *old=archive_lru.firstObject;[archive_handles removeObjectForKey:old];[archive_lru removeObjectAtIndex:0];}
        archive_handles[name]=a;
    }
    [archive_lru removeObject:name];[archive_lru addObject:name];return a;
}
- (void)openArchive {
    archive_open_attempted=YES;const char *opt=getenv("HV_PVG_ARCHIVE");
    if(opt && !strcmp(opt,"0"))return;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *dir=[[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Henge/Pipelines" isDirectory:YES];
    const char *override=getenv("HV_PVG_ARCHIVE_DIR");if(override&&*override)dir=[NSURL fileURLWithPath:@(override) isDirectory:YES];
    NSError *error=nil;if(!dir || ![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error])return;
    [dir setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    char build[64]="unknown";size_t length=sizeof build;if(sysctlbyname("kern.osversion",build,&length,NULL,0)||!build[0])return;
    NSString *gpu=[[device.name componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]componentsJoinedByString:@"-"];
    archive_dir=dir;archive_prefix=[NSString stringWithFormat:@"v3-pipelines-%s-%@-",build,gpu];
    archive_paths=[NSMutableDictionary new];archive_order=[NSMutableArray new];archive_handles=[NSMutableDictionary new];
    archive_lru=[NSMutableArray new];archive_pending=[NSMutableArray new];archive_bytes=0;archive_next=0;
    NSArray *files=[[fm contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:nil]sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){
        long long x=[[[a.lastPathComponent stringByDeletingPathExtension]componentsSeparatedByString:@"-"].lastObject longLongValue];
        long long y=[[[b.lastPathComponent stringByDeletingPathExtension]componentsSeparatedByString:@"-"].lastObject longLongValue];
        return x<y?NSOrderedAscending:x>y?NSOrderedDescending:NSOrderedSame;
    }];
    NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet;
    for(NSURL *url in files){
        NSString *name=url.lastPathComponent;
        if(![name hasPrefix:archive_prefix] || ![name hasSuffix:@".bin"] || (opt&&!strcmp(opt,"reset"))){[fm removeItemAtURL:url error:nil];continue;}
        NSString *tail=[[name substringFromIndex:archive_prefix.length]stringByDeletingPathExtension];NSArray<NSString *> *parts=[tail componentsSeparatedByString:@"-"];
        unsigned kind=parts.count==3?parts[0].intValue:0;long long number=parts.count==3?parts[2].longLongValue:-1;
        NSDictionary *attr=[fm attributesOfItemAtPath:url.path error:nil];unsigned long long bytes=attr.fileSize;
        if(parts.count!=3 || (kind!=0xe&&kind!=0xb&&kind!=0x33) || parts[1].length!=64 || [parts[1]rangeOfCharacterFromSet:hex].location!=NSNotFound || number<0 || number>=INT_MAX || ![attr.fileType isEqualToString:NSFileTypeRegular] || bytes<256 || bytes>archive_cap()){
            [fm removeItemAtURL:url error:nil];continue;
        }
        NSString *key=[NSString stringWithFormat:@"%@-%@",parts[0],parts[1]];
        NSMutableDictionary *entry=[@{@"key":key,@"url":url,@"bytes":@(bytes)}mutableCopy];
        if(!archive_paths[key])archive_paths[key]=[NSMutableArray new];[archive_paths[key]addObject:entry];[archive_order addObject:entry];archive_bytes+=bytes;
        archive_next=MAX(archive_next,(int)number+1);
        while(archive_paths[key].count>4)[self forgetArchiveFile:archive_paths[key].firstObject];
        while(archive_order.count>2048 || archive_bytes>archive_cap())[self forgetArchiveFile:archive_order.firstObject];
    }
    fprintf(stderr,"hengevm: pvg-metal: saved pipelines: %lu indexed files %.1f MB; lazy handles<=16; one pipeline per file\n",(unsigned long)archive_order.count,archive_bytes/1048576.0);
}

- (id)newState:(uint32_t)tag descriptor:(id)descriptor options:(MTLPipelineOption)options error:(NSError **)err {
    id state=nil;
    if(tag==0xe)state=[device newRenderPipelineStateWithDescriptor:descriptor options:options reflection:nil error:err];
    else if(tag==0x33)state=[device newRenderPipelineStateWithTileDescriptor:descriptor options:options reflection:nil error:err];
    else state=[device newComputePipelineStateWithDescriptor:descriptor options:options reflection:nil error:err];
    if(state && metal4 && (tag==0xe||tag==0xb)){
        id immutable=[descriptor copy];[immutable setBinaryArchives:@[]];
        objc_setAssociatedObject(state,"henge.metal4.source",@{@"tag":@(tag),@"descriptor":immutable},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

- (id)pipelineState:(uint32_t)tag descriptor:(id)descriptor error:(NSError **)err {
    double t0=now_seconds();if(t0>=cache_budget_deadline)[self refreshCacheBudget];
    if(!archive_open_attempted&&!archive_pressure_suspended)[self openArchive];
    if(err)*err=nil;[descriptor setBinaryArchives:@[]];
    BOOL saveable=tag!=0xe || [(MTLRenderPipelineDescriptor *)descriptor fragmentFunction]!=nil;
    NSString *key=archive_paths&&saveable?hv_pipeline_archive_hint(tag,descriptor):nil;
    BOOL debug=getenv("HV_PVG_ARCHIVE_DEBUG")!=NULL;
    if(debug)fprintf(stderr,"archive lookup tag=%u key=%s indexed=%lu pending=%lu\n",tag,key.UTF8String ?: "none",(unsigned long)(key?archive_paths[key].count:0),(unsigned long)archive_pending.count);
    if(key){
        for(NSDictionary *entry in archive_pending.reverseObjectEnumerator){
            if(![entry[@"key"]isEqual:key])continue;[descriptor setBinaryArchives:@[entry[@"archive"]]];
            id state=[self newState:tag descriptor:descriptor options:MTLPipelineOptionFailOnBinaryArchiveMiss error:NULL];
            if(state){pipes_hit++;hit_ms+=(now_seconds()-t0)*1000;return state;}
        }
        for(NSMutableDictionary *entry in [archive_paths[key]copy]){
            id<MTLBinaryArchive>a=[self loadArchiveFile:entry];if(!a)continue;[descriptor setBinaryArchives:@[a]];
            NSError *lookup_error=nil;
            id state=[self newState:tag descriptor:descriptor options:MTLPipelineOptionFailOnBinaryArchiveMiss error:&lookup_error];
            if(debug)fprintf(stderr,"archive file=%s hit=%d error=%s\n",[(NSURL *)entry[@"url"]lastPathComponent].UTF8String,state!=nil,lookup_error.localizedDescription.UTF8String ?: "none");
            if(state){pipes_hit++;hit_ms+=(now_seconds()-t0)*1000;return state;}
        }
    }
    [descriptor setBinaryArchives:@[]];NSError *error=nil;id state=nil;
    if(key && archive_pending.count<64){
        id<MTLBinaryArchive>a=[self emptyArchive];BOOL added=NO;
        if(a)added=tag==0xe?[a addRenderPipelineFunctionsWithDescriptor:descriptor error:&error]:tag==0x33?[a addTileRenderPipelineFunctionsWithDescriptor:descriptor error:&error]:[a addComputePipelineFunctionsWithDescriptor:descriptor error:&error];
        if(added){
            [descriptor setBinaryArchives:@[a]];
            state=[self newState:tag descriptor:descriptor options:MTLPipelineOptionFailOnBinaryArchiveMiss error:&error];
            if(state){[archive_pending addObject:@{@"key":key,@"archive":a}];pipes_unsaved++;[self scheduleArchiveSave];}
        }
        if(!state && pipes_unsaveable++<3)fprintf(stderr,"hengevm: pipeline archive bypass tag=%u: %s\n",tag,error.localizedDescription.UTF8String ?: "unavailable");
    }else if(!saveable)pipes_unsaveable++;
    if(!state){[descriptor setBinaryArchives:@[]];error=nil;state=[self newState:tag descriptor:descriptor options:MTLPipelineOptionNone error:&error];}
    if(err)*err=state?nil:error;
    if(state){pipes_compiled++;compile_ms+=(now_seconds()-t0)*1000;}

    return state;
}
- (void)scheduleArchiveSave {
    // Bound time from the FIRST pending PSO; a stream of new pipelines must
    // not postpone persistence indefinitely. A full batch still saves now.
    if(archive_save_timer && archive_pending.count<64)return;
    if(!archive_save_timer){
        archive_save_timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,worker);HvReplay *__weak weak=self;
        dispatch_source_set_event_handler(archive_save_timer,^{HvReplay *r=weak;if(r&&!atomic_load(&r->stopping))[r saveArchive];});dispatch_resume(archive_save_timer);
    }
    uint64_t delay=archive_pending.count>=64?0:8*NSEC_PER_SEC;
    dispatch_source_set_timer(archive_save_timer,dispatch_time(DISPATCH_TIME_NOW,delay),DISPATCH_TIME_FOREVER,NSEC_PER_SEC);
}
- (void)saveArchive {
    if(archive_save_timer){dispatch_source_cancel(archive_save_timer);archive_save_timer=nil;}
    NSArray *pending=[archive_pending copy];[archive_pending removeAllObjects];pipes_unsaved=0;
    NSFileManager *fm=NSFileManager.defaultManager;
    for(NSDictionary *item in pending){
        if(archive_next==INT_MAX)break;NSString *key=item[@"key"];
        NSURL *url=[archive_dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@%@-%d.bin",archive_prefix,key,archive_next]];
        NSURL *tmp=[url URLByAppendingPathExtension:@"new"];[fm removeItemAtURL:tmp error:nil];NSError *error=nil;
        id<MTLBinaryArchive>a=item[@"archive"];
        if(![a serializeToURL:tmp error:&error]){[self complain:[NSString stringWithFormat:@"saved pipeline not written: %@",error.localizedDescription]];[fm removeItemAtURL:tmp error:nil];continue;}
        unsigned long long bytes=[[fm attributesOfItemAtPath:tmp.path error:nil]fileSize];
        if(bytes<256 || bytes>archive_cap()){[fm removeItemAtURL:tmp error:nil];continue;}
        while(archive_order.count && (archive_order.count>=2048 || archive_bytes>archive_cap()-bytes))[self forgetArchiveFile:archive_order.firstObject];
        if(rename(tmp.fileSystemRepresentation,url.fileSystemRepresentation)){[fm removeItemAtURL:tmp error:nil];continue;}
        archive_next++;archive_bytes+=bytes;
        NSMutableDictionary *entry=[@{@"key":key,@"url":url,@"bytes":@(bytes)}mutableCopy];
        if(!archive_paths[key])archive_paths[key]=[NSMutableArray new];[archive_paths[key]addObject:entry];[archive_order addObject:entry];
        while(archive_paths[key].count>4)[self forgetArchiveFile:archive_paths[key].firstObject];
    }
    if(pending.count)fprintf(stderr,"hengevm: pvg-metal: saved pipelines: %lu separate PSOs; %lu files %.1f MB; bounded lazy lookup\n",(unsigned long)pending.count,(unsigned long)archive_order.count,archive_bytes/1048576.0);
}
- (void)dropArchiveMemory {
    if(archive_save_timer){dispatch_source_cancel(archive_save_timer);archive_save_timer=nil;}
    archive_paths=nil;archive_order=nil;archive_handles=nil;archive_lru=nil;archive_pending=nil;pipes_unsaved=0;
}

- (id)makeSerialized:(uint64_t)at length:(uint32_t)size task:(uint32_t)task {
    if (size < 4) return nil;
    NSMutableData *all = [NSMutableData dataWithLength:size];
    if (hv_pvg_lite_task_read(lite, task, at, all.mutableBytes, size)) return nil;
    const uint32_t *w = all.bytes;
    uint32_t tag = w[0];
    if ((tag == 0xe || tag == 0x33 || tag == 0xb) && (size < 16 || w[3] > size - 16)) {
        [self complain:@"serialized pipeline payload exceeds its record"]; return nil;
    }
    if (tag == 0xe || tag == 0x33) { /* render or tile pipeline: {tag, size, ref, length, data} */
        id descriptor = [self pipelineDescriptor:tag data:all task:task];
        if (!descriptor) return nil;
        NSError *err = nil;
        double pipeline_start = now_seconds();
        id state = [self pipelineState:tag descriptor:descriptor error:&err];
        double pipeline_elapsed = now_seconds() - pipeline_start;
        pipeline_builds++;
        pipeline_seconds += pipeline_elapsed;
        if (pipeline_elapsed > pipeline_worst_seconds) pipeline_worst_seconds = pipeline_elapsed;
        if (!state) [self complain:[NSString stringWithFormat:@"pipeline %u: %@", tag, err.localizedDescription]];
        if (tag == 0xe && getenv("HV_SHADER_DUMP") && atoi(getenv("HV_SHADER_DUMP"))) { /* m4 fork: blend state as this iOS read it */
            MTLRenderPipelineDescriptor *rp = descriptor;
            for (int i = 0; i < 4; i++) {
                MTLRenderPipelineColorAttachmentDescriptor *c = rp.colorAttachments[i];
                if (c.pixelFormat == MTLPixelFormatInvalid) continue;
                fprintf(stderr, "hvpipe: %s c%d fmt %lu blend %d rgb %lu*src %lu %lu*dst alpha %lu*src %lu %lu*dst mask %lx\n",
                        rp.fragmentFunction.name.UTF8String ?: "?", i, (unsigned long)c.pixelFormat, (int)c.blendingEnabled,
                        (unsigned long)c.sourceRGBBlendFactor, (unsigned long)c.rgbBlendOperation, (unsigned long)c.destinationRGBBlendFactor,
                        (unsigned long)c.sourceAlphaBlendFactor, (unsigned long)c.alphaBlendOperation, (unsigned long)c.destinationAlphaBlendFactor,
                        (unsigned long)c.writeMask);
            }
        }
        if (state && tag == 0xe && getenv("HV_PVG_TRACE_FILE")) {
            MTLRenderPipelineDescriptor *rp = descriptor;
            objc_setAssociatedObject(state, "hvname", [NSString stringWithFormat:@"%@ / %@ -> fmt %lu blend %d", rp.vertexFunction.name, rp.fragmentFunction.name, (unsigned long)rp.colorAttachments[0].pixelFormat, (int)rp.colorAttachments[0].blendingEnabled], OBJC_ASSOCIATION_RETAIN);
        }
        return state;
    }
    if (tag == 0xb) { /* compute pipeline: {tag, size, ref, length, data} */
        id descriptor = [self pipelineDescriptor:tag data:all task:task];
        if (!descriptor) return nil;
        NSError *err = nil;
        double pipeline_start = now_seconds();
        id state = [self pipelineState:tag descriptor:descriptor error:&err];
        double pipeline_elapsed = now_seconds() - pipeline_start;
        pipeline_builds++;
        pipeline_seconds += pipeline_elapsed;
        if (pipeline_elapsed > pipeline_worst_seconds) pipeline_worst_seconds = pipeline_elapsed;
        if (!state) [self complain:[NSString stringWithFormat:@"compute pipeline: %@", err.localizedDescription]];
        else objc_setAssociatedObject(state, "hvname", [NSString stringWithFormat:@"compute %@", [[descriptor computeFunction] name]], OBJC_ASSOCIATION_RETAIN);
        return state;
    }
    if (tag == 3) { /* sampler: {tag, size, ref, bits, lod min, lod max, ...} */
        uint64_t bits;
        memcpy(&bits, w + 3, 8);
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.minFilter = (MTLSamplerMinMagFilter)(bits & 3);
        d.magFilter = (MTLSamplerMinMagFilter)((bits >> 2) & 3);
        d.lodAverage = (bits >> 4) & 1;
        d.compareFunction = (MTLCompareFunction)((bits >> 5) & 7);
        d.sAddressMode = (MTLSamplerAddressMode)((bits >> 8) & 15);
        d.tAddressMode = (MTLSamplerAddressMode)((bits >> 12) & 15);
        d.rAddressMode = (MTLSamplerAddressMode)((bits >> 16) & 15);
        d.borderColor = (MTLSamplerBorderColor)((bits >> 20) & 15);
        d.mipFilter = (MTLSamplerMipFilter)((bits >> 24) & 3);
        NSUInteger aniso = (bits >> 26) & 31;
        d.maxAnisotropy = aniso ? aniso : 1;
        d.normalizedCoordinates = (bits >> 31) & 1;
        d.supportArgumentBuffers = (bits >> 32) & 1;
        float lod[2];
        memcpy(lod, w + 5, 8);
        d.lodMinClamp = lod[0], d.lodMaxClamp = lod[1];
        id s = [device newSamplerStateWithDescriptor:d];
        if(s && metal4){
            objc_setAssociatedObject(s,"henge.metal4.sampler.descriptor",[d copy],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            MTLSamplerDescriptor *m=[d copy];m.supportArgumentBuffers=YES;
            id variant=[device newSamplerStateWithDescriptor:m];
            if(variant)objc_setAssociatedObject(s,"henge.metal4.sampler",variant,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!s) [self complain:@"sampler failed"];
        return s;
    }
    if (tag == 0xd) return [device newFence];
    if (tag == 4) { /* depth and stencil: {tag, size, ref, flags, front {ops, read, write}, back {...}} */
        MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
        uint32_t f = w[3];
        d.depthCompareFunction = (MTLCompareFunction)(f & 7);
        d.depthWriteEnabled = (f >> 3) & 1;
        for (int side = 0; side < 2; side++) {
            if (!((f >> (4 + side)) & 1)) continue;
            const uint32_t *t = w + 4 + side * 3;
            MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
            sd.stencilCompareFunction = (MTLCompareFunction)(t[0] & 7);
            sd.stencilFailureOperation = (MTLStencilOperation)((t[0] >> 3) & 7);
            sd.depthFailureOperation = (MTLStencilOperation)((t[0] >> 6) & 7);
            sd.depthStencilPassOperation = (MTLStencilOperation)((t[0] >> 9) & 7);
            sd.readMask = t[1], sd.writeMask = t[2];
            if (side == 0) d.frontFaceStencil = sd;
            else d.backFaceStencil = sd;
        }
        return [device newDepthStencilStateWithDescriptor:d];
    }
    [self complain:[NSString stringWithFormat:@"serialized object tag %u", tag]];
    return nil;
}

/* A heap: {guest page, length, flags}. As on Apple's host its memory is the GPU's
   own, filled from the guest's pages when the guest says those changed. */
- (void)makeHeap:(HvObject *)o at:(uint64_t)at task:(uint32_t)task {
    struct __attribute__((packed)) { uint32_t vpage; uint64_t length; uint8_t flags; } h;
    if (hv_pvg_lite_task_read(lite, task, at, &h, sizeof h)) return;
    MTLHeapDescriptor *d = [MTLHeapDescriptor new];
    d.size = (NSUInteger)h.length;
    d.type = MTLHeapTypePlacement;
    d.storageMode = MTLStorageModePrivate;
    d.hazardTrackingMode = h.flags & 2 ? MTLHazardTrackingModeTracked : MTLHazardTrackingModeDefault;
    id<MTLHeap> heap = [device newHeapWithDescriptor:d];
    if (!heap && d.hazardTrackingMode == MTLHazardTrackingModeTracked) { /* not every GPU tracks placement heaps */
        d.hazardTrackingMode = MTLHazardTrackingModeDefault;
        heap = [device newHeapWithDescriptor:d];
        [self complain:@"placement heaps here cannot be tracked"];
    }
    if (!heap) { [self complain:[NSString stringWithFormat:@"heap of %llu bytes failed", h.length]]; return; }
    o->object = heap;
    o->heap_whole = [heap newBufferWithLength:(NSUInteger)h.length options:MTLResourceStorageModePrivate offset:0];
    o->length = (h.length + 0x3fff) & ~0x3fffull;
    o->vpage = h.vpage;
    o->guest_backed = YES;
    heap_bytes += h.length;
    if (getenv("HV_PVG_HEAP_LOG")) fprintf(stderr, "hengevm: pvg-metal: heap %llu KB at page %u, flags %x, now %llu MB of heaps\n", h.length >> 10, h.vpage, h.flags, heap_bytes >> 20);
}

/* A buffer in a heap: {heap, offset, length}. */
- (void)makeHeapBuffer:(HvObject *)o at:(uint64_t)at task:(uint32_t)task {
    struct __attribute__((packed)) { uint32_t heap; uint64_t offset, length; } h;
    if (hv_pvg_lite_task_read(lite, task, at, &h, sizeof h)) return;
    HvObject *parent = [self object:h.heap task:task];
    id<MTLHeap> heap = parent ? parent->object : nil;
    o->parent = parent;
    o->object = [heap newBufferWithLength:(NSUInteger)h.length options:MTLResourceStorageModePrivate offset:(NSUInteger)h.offset];
    if (!o->object) {
        [self complain:[NSString stringWithFormat:@"heap buffer: %llu bytes at %llu of ref %u failed", h.length, h.offset, h.heap]];
        o->object = [device newBufferWithLength:(NSUInteger)h.length options:MTLResourceStorageModePrivate];
    }
}

- (void)makeBuffer:(HvObject *)o at:(uint64_t)at task:(uint32_t)task {
    struct __attribute__((packed)) { uint64_t length; uint32_t vpage; uint32_t flags; } h;
    if (hv_pvg_lite_task_read(lite, task, at, &h, sizeof h)) return;
    o->length = (h.length + 0x3fff) & ~0x3fffull;
    o->vpage = h.vpage;
    if (!map_pages(self, task, o)) return;
    o->plain_buffer = YES;
    o->object = buffer_over_mapping(self, o);
    if (!o->object) [self complain:@"buffer failed"];
}

- (void)makeTexture:(HvObject *)o at:(uint64_t)at size:(uint32_t)size task:(uint32_t)task {
    NSMutableData *all = [NSMutableData dataWithLength:size];
    if (hv_pvg_lite_task_read(lite, task, at, all.mutableBytes, size)) return;
    const uint8_t *d = all.bytes;
    /* {length, page}, a layout table, {tag, size, ref}, the description. */
    memcpy(&o->length, d, 8);
    memcpy(&o->vpage, d + 8, 4);
    const uint8_t *layout = d + 12;
    o->tex_mips = *(const uint16_t *)layout & 0x3fff;
    o->tex_slices = *(const uint16_t *)(layout + 2);
    memcpy(&o->tex_base, layout + 4, 8);
    memcpy(&o->tex_stride, layout + 12, 8);
    o->tex_block_h = layout[0x15];
    uint32_t table = o->tex_mips * 36;
    if (12 + 0x18 + table + 12 > size) { [self complain:@"texture entry too small"]; return; }
    o->tex_layout = malloc(table);
    memcpy(o->tex_layout, layout + 0x18, table);
    const uint8_t *rec = layout + 0x18 + table;
    uint32_t tag = *(const uint32_t *)rec;
    MTLTextureDescriptor *t = (tag == 0x34 || tag == 0x39) ? descriptor_v2(rec + 12) : descriptor_v1(rec + 12);
    t.storageMode = MTLStorageModePrivate;
    t.usage |= MTLTextureUsageShaderRead;
    o->object = [device newTextureWithDescriptor:t];
    o->guest_backed = YES;
    if (!o->object) [self complain:[NSString stringWithFormat:@"texture format %lu %lux%lu failed", (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height]];
}

/* A texture over a buffer: {tag 9, size, ref, buffer ref, offset, bytes per row, description}. */
- (void)makeLinearTexture:(HvObject *)o at:(uint64_t)at size:(uint32_t)size task:(uint32_t)task {
    struct __attribute__((packed)) { uint32_t tag, size, ref, buffer; uint64_t offset, row; uint8_t d[64]; } h;
    memset(&h, 0, sizeof h);
    if (hv_pvg_lite_task_read(lite, task, at, &h, MIN(size, (uint32_t)sizeof h))) return;
    if (h.tag == 0x34 || h.tag == 0x14 || h.tag == 1) { /* no guest memory at all: {tag, size, ref, description} */
        const uint8_t *desc = (const uint8_t *)&h.buffer;
        MTLTextureDescriptor *t = h.tag == 0x34 ? descriptor_v2(desc) : descriptor_v1(desc);
        t.storageMode = MTLStorageModePrivate;
        o->object = [device newTextureWithDescriptor:t];
        if (!o->object) [self complain:[NSString stringWithFormat:@"texture format %lu %lux%lu samples %lu failed", (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.sampleCount]];
        return;
    }
    if (h.tag == 0x15 || h.tag == 0x38) { /* in a heap: {tag, size, ref, heap, description, offset after 0x24 or 0x2c} */
        const uint8_t *desc = (const uint8_t *)&h.offset;
        uint64_t offset;
        memcpy(&offset, desc + (h.tag == 0x38 ? 0x2c : 0x24), 8);
        HvObject *parent = [self object:h.buffer task:task];
        id<MTLHeap> heap = parent ? parent->object : nil;
        MTLTextureDescriptor *t = h.tag == 0x38 ? descriptor_v2(desc) : descriptor_v1(desc);
        t.resourceOptions = heap ? heap.resourceOptions : MTLResourceStorageModePrivate;
        o->parent = parent;
        o->object = [heap newTextureWithDescriptor:t offset:(NSUInteger)offset];
        if (!o->object) {
            [self complain:[NSString stringWithFormat:@"heap texture format %lu %lux%lu at %llu of ref %u failed", (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height, offset, h.buffer]];
            t.storageMode = MTLStorageModePrivate;
            o->object = [device newTextureWithDescriptor:t];
        }
        return;
    }
    if (h.tag == 7 || h.tag == 8 || h.tag == 0x1b) { /* a view: {tag, size, ref, parent, format u16, type u16, levels, slices, swizzle} */
        struct __attribute__((packed)) { uint16_t format, type; uint64_t levels[2], slices[2]; uint8_t swizzle[4]; } v;
        memcpy(&v, &h.offset, sizeof v);
        HvObject *parent = [self object:h.buffer task:task];
        id<MTLTexture> from = parent ? parent->object : nil;
        if (!from) { [self complain:[NSString stringWithFormat:@"view of nothing (tag %u, ref %u)", h.tag, h.buffer]]; return; }
        o->parent = parent;
        o->surface = parent->surface;
        NSRange levels = NSMakeRange((NSUInteger)v.levels[0], (NSUInteger)v.levels[1]), slices = NSMakeRange((NSUInteger)v.slices[0], (NSUInteger)v.slices[1]);
        if (h.tag == 7) o->object = [from newTextureViewWithPixelFormat:(MTLPixelFormat)v.format];
        else if (h.tag == 8) o->object = [from newTextureViewWithPixelFormat:(MTLPixelFormat)v.format textureType:(MTLTextureType)v.type levels:levels slices:slices];
        else o->object = [from newTextureViewWithPixelFormat:(MTLPixelFormat)v.format textureType:(MTLTextureType)v.type levels:levels slices:slices
                                                     swizzle:safe_swizzle(v.swizzle, (const uint8_t *)&v, sizeof v, "view")];
        if (!o->object) [self complain:[NSString stringWithFormat:@"view tag %u of format %lu as %u failed", h.tag, (unsigned long)from.pixelFormat, v.format]];
        return;
    }
    if (h.tag != 9 && h.tag != 0x37) {
        uint32_t w[24] = {0};
        hv_pvg_lite_task_read(lite, task, at, w, sizeof w);
        NSMutableString *m = [NSMutableString stringWithFormat:@"serialized texture tag %u:", h.tag];
        for (int i = 0; i < 24; i++) [m appendFormat:@" %08x", w[i]];
        [self complain:m];
        return;
    }
    HvObject *b = [self object:h.buffer task:task];
    id<MTLBuffer> buffer = b ? b->object : nil;
    if (!buffer || ![buffer conformsToProtocol:@protocol(MTLBuffer)]) { [self complain:@"linear texture without a buffer"]; return; }
    MTLTextureDescriptor *t = h.tag == 0x37 ? descriptor_v2(h.d) : descriptor_v1(h.d);
    t.resourceOptions = buffer.resourceOptions;
    set_framebuffer_only(t, NO);
    t.usage |= MTLTextureUsageShaderRead;
    o->parent = b;
    o->follows = b, o->follows_generation = b->generation;
    if (linear_texture_fits(device, t, h.offset, h.row, buffer.length)) o->object = [buffer newTextureWithDescriptor:t offset:h.offset bytesPerRow:h.row];
    if (!o->object) [self complain:[NSString stringWithFormat:@"linear texture format %lu row %llu failed", (unsigned long)t.pixelFormat, h.row]];
}

/* A multi-plane surface as a real IOSurface, laid out as the guest laid it out.
   Planes are in the descriptor from +0x80, 0x80 apart: offset +8, size +0x18,
   width +0x20, height +0x28, row +0x30, bytes per element +0x38. */
/* compact: macOS 14's description, 0x40 bytes of header then 0x40 a plane: offset +0x0c, size +0x10, width and height
   << 8 at +0x14 and +0x18, row +0x1c, bytes per element +0x20 (x420 3840x2160: luma at 0x200, 8000-byte rows, 2 bytes;
   chroma at 0x1194400, 1920x1080, 4 bytes). The plane count is the u32 at +0x24. */
static void read_plane(const uint8_t *desc, BOOL compact, uint32_t i, uint64_t *o_off, uint64_t *o_size, uint64_t *o_w, uint64_t *o_h,
                       uint64_t *o_row, uint16_t *o_bpe) {
    const uint8_t *pl = desc + 0x80 + i * 0x80;
    uint64_t off, size, w, h, row;
    uint16_t bpe;
    if (compact) {
        const uint8_t *cp = desc + 0x40 + i * 0x40;
        uint32_t v[6], base;
        memcpy(v, cp + 0x0c, sizeof v); /* offset, size, width << 8, height << 8, row, bytes per element */
        off = v[0], size = v[1], w = v[2] >> 8, h = v[3] >> 8, row = v[4], bpe = (uint16_t)v[5];
        /* +0x08: where the plane's first visible pixel is. A video decoder's buffers carry extended pixels
           around the picture (Sonoma's 10-bit HEVC: 96 columns and 71 rows before it), and the guest's
           GPU reads the plane from there; from the allocation's start, every converted frame came out
           moved right and down with a green band at the top and left (the menu bar and left strip). */
        memcpy(&base, cp + 0x08, 4);
        if (base > off && base - off < size) size -= base - off, off = base;
    } else
    memcpy(&off, pl + 8, 8), memcpy(&size, pl + 0x18, 8), memcpy(&w, pl + 0x20, 8), memcpy(&h, pl + 0x28, 8), memcpy(&row, pl + 0x30, 8), memcpy(&bpe, pl + 0x38, 2);
    *o_off = off, *o_size = size, *o_w = w, *o_h = h, *o_row = row, *o_bpe = bpe;
}

static uint32_t plane_count(const uint8_t *desc, BOOL compact) {
    uint32_t planes = desc[0x3e];
    if (compact) memcpy(&planes, desc + 0x24, 4);
    return planes;
}

/* Where each plane is in the guest's memory, without making anything. */
static void plane_layout(HvObject *to, const uint8_t *desc, BOOL compact) {
    uint32_t planes = plane_count(desc, compact);
    for (uint32_t i = 0; i < planes && i < 4; i++) {
        uint64_t off, size, w, h, row;
        uint16_t bpe;
        read_plane(desc, compact, i, &off, &size, &w, &h, &row, &bpe);
        to->plane_from[i] = off, to->plane_row[i] = row, to->plane_h[i] = h;
    }
    to->plane_count = MIN(planes, 4u);
}

static IOSurfaceRef make_iosurface(HvObject *to, const uint8_t *desc, uint64_t alloc, BOOL compact) {
    uint32_t fourcc, planes = desc[0x3e];
    uint64_t width, height;
    memcpy(&fourcc, desc + 4, 4), memcpy(&width, desc + 0x20, 8), memcpy(&height, desc + 0x28, 8);
    if (compact) {
        uint32_t w32, h32;
        memcpy(&w32, desc + 0x14, 4), memcpy(&h32, desc + 0x18, 4), memcpy(&planes, desc + 0x24, 4);
        width = w32 >> 8, height = h32 >> 8;
    }
    NSMutableArray *info = [NSMutableArray new], *plain = [NSMutableArray new];
    uint64_t at = 0;
    for (uint32_t i = 0; i < planes && i < 4; i++) {
        const uint8_t *pl = desc + 0x80 + i * 0x80;
        uint64_t off, size, w, h, row;
        uint16_t bpe;
        if (compact) {
            const uint8_t *cp = desc + 0x40 + i * 0x40;
            uint32_t v[6], base;
            memcpy(v, cp + 0x0c, sizeof v); /* offset, size, width << 8, height << 8, row, bytes per element */
            off = v[0], size = v[1], w = v[2] >> 8, h = v[3] >> 8, row = v[4], bpe = (uint16_t)v[5];
            /* +0x08: where the plane's first visible pixel is. A video decoder's buffers carry extended pixels
               around the picture (Sonoma's 10-bit HEVC: 96 columns and 71 rows before it), and the guest's
               GPU reads the plane from there; from the allocation's start, every converted frame came out
               moved right and down with a green band at the top and left (the menu bar and left strip). */
            memcpy(&base, cp + 0x08, 4);
            if (base > off && base - off < size) size -= base - off, off = base;
        } else
        memcpy(&off, pl + 8, 8), memcpy(&size, pl + 0x18, 8), memcpy(&w, pl + 0x20, 8), memcpy(&h, pl + 0x28, 8), memcpy(&row, pl + 0x30, 8), memcpy(&bpe, pl + 0x38, 2);
        [info addObject:@{(__bridge id)kIOSurfacePlaneWidth: @(w), (__bridge id)kIOSurfacePlaneHeight: @(h), (__bridge id)kIOSurfacePlaneBytesPerRow: @(row),
                          (__bridge id)kIOSurfacePlaneOffset: @(off), (__bridge id)kIOSurfacePlaneSize: @(size), (__bridge id)kIOSurfacePlaneBytesPerElement: @(bpe),
                          (__bridge id)kIOSurfacePlaneElementWidth: @1, (__bridge id)kIOSurfacePlaneElementHeight: @1}];
        [plain addObject:@{(__bridge id)kIOSurfacePlaneWidth: @(w), (__bridge id)kIOSurfacePlaneHeight: @(h), (__bridge id)kIOSurfacePlaneBytesPerRow: @(row),
                           (__bridge id)kIOSurfacePlaneOffset: @(at), (__bridge id)kIOSurfacePlaneSize: @(row * h), (__bridge id)kIOSurfacePlaneBytesPerElement: @(bpe),
                           (__bridge id)kIOSurfacePlaneElementWidth: @1, (__bridge id)kIOSurfacePlaneElementHeight: @1}];
        to->plane_from[i] = off, to->plane_row[i] = row, to->plane_h[i] = h;
        at += row * h;
    }
    NSDictionary *props = @{(__bridge id)kIOSurfaceWidth: @(width), (__bridge id)kIOSurfaceHeight: @(height), (__bridge id)kIOSurfacePixelFormat: @(fourcc),
                            (__bridge id)kIOSurfaceAllocSize: @(alloc), (__bridge id)kIOSurfacePlaneInfo: info};
    IOSurfaceRef made = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!made) {
        /* Video formats can refuse the guest's padding: request packed planes instead. */
        NSDictionary *plain_props = @{(__bridge id)kIOSurfaceWidth: @(width), (__bridge id)kIOSurfaceHeight: @(height), (__bridge id)kIOSurfacePixelFormat: @(fourcc), (__bridge id)kIOSurfacePlaneInfo: plain};
        made = IOSurfaceCreate((__bridge CFDictionaryRef)plain_props);
    }
    if (made) {
        to->plane_count = planes;
        static int logged;
        if (planes >= 2 && logged++ < 4)
            for (uint32_t i = 0; i < planes && i < IOSurfaceGetPlaneCount(made) && i < 4; i++)
                fprintf(stderr, "hengevm: video plane %u guest off %llu row %llu h %llu; host row %zu h %zu\n",
                        i, (unsigned long long)to->plane_from[i], (unsigned long long)to->plane_row[i],
                        (unsigned long long)to->plane_h[i], IOSurfaceGetBytesPerRowOfPlane(made, i),
                        IOSurfaceGetHeightOfPlane(made, i));
    }
    return made;
}

#include "surface_hash.h"
#include "gpu_copy_bounds.h"
static uint64_t hash_bytes(const uint8_t *from, uint64_t len) {
    return hv_surface_hash(from, len);
}

static uint64_t guest_hash(HvObject *s) { return hash_bytes(s->mapped + s->first, s->alloc); }

/* Plane i of a multi-plane surface in the guest's memory, or 0 bytes if its layout does not fit the allocation. */
static uint64_t plane_bytes(HvObject *s, uint32_t i) {
    uint64_t row = s->plane_row[i], off = s->plane_from[i];
    if (!row || off > s->alloc || s->plane_h[i] > (s->alloc - off) / row) return 0;
    return row * s->plane_h[i];
}

/* Guest pixels into its IOSurface, when they changed. */
static void sync_iosurface(HvObject *s) {
    if (!s->iosurface) return;
    const uint8_t *from = s->mapped + s->first;
    BOOL by_plane = s->plane_count && IOSurfaceGetPlaneCount(s->iosurface) >= s->plane_count;
    uint64_t hashes[4] = {0}, content_hash = 0;
    uint32_t changed = 0;
    uint64_t *have = s->shared_hashes ? (uint64_t *)s->shared_hashes.mutableBytes : s->plane_hash;
    if (by_plane) {
        for (uint32_t i = 0; i < s->plane_count && i < 4; i++) {
            uint64_t bytes = plane_bytes(s, i);
            hashes[i] = hash_bytes(from + (bytes ? s->plane_from[i] : 0), bytes);
            if (hashes[i] != have[i]) changed |= 1u << i;
        }
        if (!changed) return;
    } else {
        uint64_t hash = guest_hash(s);
        if (hash == s->content_hash) return;
        content_hash = hash;
    }
    if (IOSurfaceLock(s->iosurface, 0, NULL) != 0) return;
    /* HV_PVG_HOST_DUMP=prefix (debugging): the host surface as it is just before the guest's pixels go over it,
       for the first few multi-plane surfaces, with its layout in a .txt beside it: did the GPU draw something here
       that this copy throws away? */
    const char *host_dump = getenv("HV_PVG_HOST_DUMP");
    static int host_dumped;
    if (host_dump && s->plane_count && host_dumped < 12) {
        char path[1100];
        snprintf(path, sizeof path, "%s-%d.bin", host_dump, host_dumped);
        FILE *f = fopen(path, "wb");
        if (f) fwrite(IOSurfaceGetBaseAddress(s->iosurface), 1, IOSurfaceGetAllocSize(s->iosurface), f), fclose(f);
        snprintf(path, sizeof path, "%s-%d.txt", host_dump, host_dumped++);
        f = fopen(path, "w");
        if (f) {
            fprintf(f, "fourcc %08x w %zu h %zu alloc %zu guest %llu\n", IOSurfaceGetPixelFormat(s->iosurface), IOSurfaceGetWidth(s->iosurface),
                    IOSurfaceGetHeight(s->iosurface), IOSurfaceGetAllocSize(s->iosurface), (unsigned long long)s->alloc);
            for (size_t i = 0; i < IOSurfaceGetPlaneCount(s->iosurface); i++)
                fprintf(f, "plane %zu off %ld row %zu h %zu w %zu bpe %zu\n", i,
                        (long)((uint8_t *)IOSurfaceGetBaseAddressOfPlane(s->iosurface, i) - (uint8_t *)IOSurfaceGetBaseAddress(s->iosurface)),
                        IOSurfaceGetBytesPerRowOfPlane(s->iosurface, i), IOSurfaceGetHeightOfPlane(s->iosurface, i),
                        IOSurfaceGetWidthOfPlane(s->iosurface, i), IOSurfaceGetBytesPerElementOfPlane(s->iosurface, i));
            fclose(f);
        }
    }
    if (by_plane) {
        /* IOSurface can choose different offsets and row strides from those
           requested. Copy each changed video plane through its actual host layout. */
        for (uint32_t i = 0; i < s->plane_count && i < 4; i++) {
            if (!(changed & 1u << i)) continue;
            uint8_t *dst = IOSurfaceGetBaseAddressOfPlane(s->iosurface, i);
            size_t dst_row = IOSurfaceGetBytesPerRowOfPlane(s->iosurface, i);
            size_t rows = MIN((size_t)s->plane_h[i], IOSurfaceGetHeightOfPlane(s->iosurface, i));
            uint64_t src_row = s->plane_row[i], src_off = s->plane_from[i];
            if (!dst || !src_row || src_off > s->alloc || rows > (s->alloc - src_off) / src_row) continue;
            size_t bytes = MIN((size_t)src_row, dst_row);
            for (size_t y = 0; y < rows; y++)
                memcpy(dst + y * dst_row, from + src_off + y * src_row, bytes);
            if (bytes && rows == s->plane_h[i]) have[i] = hashes[i];
        }
    } else {
        uint8_t *base = IOSurfaceGetBaseAddress(s->iosurface);
        size_t copied = MIN(s->alloc, IOSurfaceGetAllocSize(s->iosurface));
        if (base && copied) memcpy(base, from, copied);
        if (base && copied == s->alloc) s->content_hash = content_hash;
    }
    IOSurfaceUnlock(s->iosurface, 0, NULL);
    const char *dump = getenv("HV_PVG_SURFACE_DUMP");
    static int dumped;
    if (dump && s->plane_count && dumped < 6) {
        char path[1100];
        snprintf(path, sizeof path, "%s-%d.bin", dump, dumped++);
        FILE *f = fopen(path, "wb");
        if (f) fwrite(from, 1, s->alloc, f), fclose(f);
    }
}

/* Metal resource contents are stable for a submitted exec. Multiple texture views
   can name exactly the same surface; only its first reference needs the CPU hash.
   Different surface objects retain independent checks, even if their host IOSurface aliases. */
static void sync_surface_once(HvReplay *r, HvObject *s, uint64_t epoch) {
    if (!s || !s->iosurface) return;
    if (epoch && s->sync_epoch == epoch) { r->surface_checks_avoided++; return; }
    r->surface_checks++;
    sync_iosurface(s);
    s->sync_epoch = epoch;
}

- (void)preparePlanar:(HvObject *)surface descriptor:(const uint8_t *)desc compact:(BOOL)compact identity:(NSData *)identity {
    plane_layout(surface,desc,compact);
    BOOL reused=NO;
    HvPlanarEntry *entry=hv_planar_resolve(planar,identity,^HvPlanarEntry *{
        /* Safari b3a8 only: verify both canonical plane views before committing
           this allocation to guest pages. Other video formats retain the
           existing IOSurface path. Backing is immutable for the entry lifetime. */
        BOOL direct=[device supportsFamily:MTLGPUFamilyApple9] && surface->fourcc=='b3a8' && surface->mapping_in_buffer && surface->plane_count==2 &&
                    !(getenv("HV_PVG_PLANAR_COPY") && strcmp(getenv("HV_PVG_PLANAR_COPY"),"0"));
        const MTLPixelFormat formats[]={MTLPixelFormatBGR10_XR,MTLPixelFormatR8Unorm};
        for(unsigned i=0;direct && i<2;i++){
            uint64_t off,size,w,h,row;uint16_t bpe;
            read_plane(desc,compact,i,&off,&size,&w,&h,&row,&bpe);
            if(!w || !h || w>16384 || h>16384 || off>UINT64_MAX-surface->first){direct=NO;break;}
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[i] width:w height:h mipmapped:NO];
            d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
            id<MTLBuffer> buffer=surface->object;
            if(!linear_texture_fits(device,d,surface->first+off,row,buffer.length) ||
               ![buffer newTextureWithDescriptor:d offset:surface->first+off bytesPerRow:row])direct=NO;
        }
        IOSurfaceRef made=direct?NULL:make_iosurface(surface,desc,surface->alloc,compact);
        if(!direct && !made)return nil;
        HvPlanarEntry *created=[[HvPlanarEntry alloc]initWithSurface:made];
        if(made)CFRelease(made);
        created->shared_pages=direct;created->pages=direct?surface->object:nil;
        created->count=surface->plane_count;
        memcpy(created->from,surface->plane_from,sizeof created->from);
        memcpy(created->row,surface->plane_row,sizeof created->row);
        memcpy(created->height,surface->plane_h,sizeof created->height);
        return created;
    },&reused);
    if(!entry){[self complain:@"surface has no compatible planar backing"];return;}
    surface->planar_key=identity;surface->planar_entry=entry;entry->mapping_users++;
    surface->plane_count=entry->count;
    memcpy(surface->plane_from,entry->from,sizeof entry->from);
    memcpy(surface->plane_row,entry->row,sizeof entry->row);
    memcpy(surface->plane_h,entry->height,sizeof entry->height);
    if(entry->shared_pages){
        surface->object=entry->pages;surface->mapped=entry->pages.contents;surface->mapping_in_buffer=YES;
    }else{
        surface->iosurface=(IOSurfaceRef)CFRetain(entry->surface);surface->shared_hashes=entry->hashes;
        sync_iosurface(surface);
    }
    if(reused)planar_reuses++;else planar_creations++;
}

/* A surface (IOSurface in the guest): a texture over its guest pages, so the
   guest's CPU and the GPU see the same pixels, as they do through a real one.
   {mapping id, tag, size, ref, description}. Its descriptor: page list at +0
   (physical >> 12, bit 0 present, one per 16 KB), first-page offset +0x60,
   allocation +0x18, bytes per row +0x30. */
/* A guest surface (IOSurface) from its description: its pages in one host buffer (or a real IOSurface for planes). */
- (HvObject *)newSurface:(uint64_t)mapping {
    NSNumber *key = @(mapping);
    HvObject *surface = nil;
    const uint8_t *desc = hv_pvg_lite_surface(lite, (uint32_t)mapping);
    if (!desc) { [self complain:[NSString stringWithFormat:@"surface %llu has no descriptor", mapping]]; return nil; }
    uint32_t list, first;
    uint64_t alloc, row;
    /* macOS 15 and later: u64 allocation, width, height and row at 0x18..0x30, plane count at 0x3e, first byte at 0x60.
       macOS 14's driver writes a compact one: u32 allocation at 0x10, width and height << 8 at 0x14 and 0x18, u32 row
       at 0x1c, bytes per pixel at 0x20 (BGRA 1920x1080: 007ec000 00078080 00043880 00001e00 00000004); one plane. */
    BOOL compact = hv_pvg_lite_old_driver(lite) != 0;
    if (getenv("HV_PVG_DESC_DUMP")) {
        fprintf(stderr, "surface-desc %llu:", mapping);
        for (int i = 0; i < 0x200; i += 4) fprintf(stderr, "%s%08x", i % 32 ? " " : "\n  ", *(const uint32_t *)(desc + i));
        fprintf(stderr, "\n");
    }
    uint32_t compact_planes = 1;
    if (compact) memcpy(&compact_planes, desc + 0x24, 4);
    uint8_t planes = compact ? (uint8_t)MIN(MAX(compact_planes, 1u), 4u) : desc[0x3e];
    memcpy(&list, desc, 4), memcpy(&alloc, desc + 0x18, 8), memcpy(&row, desc + 0x30, 8), memcpy(&first, desc + 0x60, 4);
    if (compact) {
        uint32_t a32, r32;
        memcpy(&a32, desc + 0x10, 4), memcpy(&r32, desc + 0x1c, 4);
        alloc = a32, row = r32, first = 0;
    }
    surface = [HvObject new];
    if (compact) memcpy(surface->described, desc, sizeof surface->described);
    surface->length = (alloc + first + 0x3fff) & ~0x3fffull;
    surface->row = row;
    surface->first = first;
    uint64_t sw, sh;
    memcpy(&sw, desc + 0x20, 8), memcpy(&sh, desc + 0x28, 8), memcpy(&surface->fourcc, desc + 4, 4);
    if (compact) {
        uint32_t w32, h32;
        memcpy(&w32, desc + 0x14, 4), memcpy(&h32, desc + 0x18, 4);
        sw = w32 >> 8, sh = h32 >> 8;
    }
    surface->surface_w = (uint32_t)sw, surface->surface_h = (uint32_t)sh;
    uint64_t n = surface->length >> 14;
    vm_address_t surface_base = 0;
    const uint32_t *pages = (list & 1) ? hv_pvg_lite_phys(lite, (uint64_t)(list & ~1u) << 12, n * 4) : NULL;
    if (!pages || vm_allocate(mach_task_self(), &surface_base, surface->length, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        [self complain:[NSString stringWithFormat:@"surface %llu has no pages", mapping]];
        return nil;
    }
    surface->mapped = (uint8_t *)surface_base;
    for (uint64_t i = 0; i < n; i++) {
        if (!(pages[i] & 1)) continue;
        uint8_t *src = hv_pvg_lite_phys(lite, (uint64_t)(pages[i] & ~1u) << 12, 0x4000);
        if (!src) continue;
        vm_address_t to = surface_base + (i << 14);
        vm_prot_t cur, max;
        vm_remap(mach_task_self(), &to, 0x4000, 0, VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)src, FALSE, &cur, &max, VM_INHERIT_NONE);
    }
    surface->object = [device newBufferWithBytesNoCopy:surface->mapped length:surface->length options:MTLResourceStorageModeShared
                                           deallocator:^(void *at, NSUInteger size) { vm_deallocate(mach_task_self(), (vm_address_t)at, size); }];
    surface->mapping_in_buffer = surface->object != nil;
    surfaces[key] = surface;
    if (planes >= 2) {
        surface->alloc = alloc;
        // Include every backing page and the actual driver's layout, not just
        // the first page: another process may share only part of an allocation.
        NSData *identity;
        if (compact) {
            NSMutableData *key = [NSMutableData dataWithBytes:desc + 4 length:0x13c];
            [key appendBytes:pages length:(NSUInteger)n * sizeof(uint32_t)];
            identity = [key copy];
        } else identity = hv_planar_identity(desc, pages, n);
        [self preparePlanar:surface descriptor:desc compact:compact identity:identity];

    }
    fprintf(stderr, "hengevm: pvg-metal: surface %llu: %llux%llu, row %llu, %llu KB, fourcc %c%c%c%c planes %u\n", mapping, (unsigned long long)sw, (unsigned long long)sh, row, alloc >> 10, desc[7], desc[6], desc[5], desc[4], planes);
        return surface;
}

/* The surface under a mapping id as the guest describes it now. macOS 14's driver reuses ids for new surfaces
   without saying the old one went: a different description under the same id is a new surface (a 1920x48 BGRA
   strip, then the 1920x1080 half-float screen). */
- (HvObject *)currentSurface:(uint64_t)mapping {
    HvObject *surface = surfaces[@(mapping)];
    if (surface && hv_pvg_lite_old_driver(lite)) {
        const uint8_t *now = hv_pvg_lite_surface(lite, (uint32_t)mapping);
        if (now && (now[0] | now[0x10]) && memcmp(surface->described, now, sizeof surface->described)) {
            if (surface->planar_entry) hv_planar_release_mapping(planar, surface->planar_key, surface->planar_entry);
            [surfaces removeObjectForKey:@(mapping)];
            surface = nil;
        }
    }
    return surface ? surface : [self newSurface:mapping];
}

- (void)makeMappedTexture:(HvObject *)o at:(uint64_t)at task:(uint32_t)task {
    /* d holds a v2 description (tag 0x39, 0x38 bytes) whose swizzle sits at +0x23..0x26: with only 32 bytes
       read those came from the stack, and macOS 27.2's first surface made Metal abort Henge (swizzle 193). */
    struct __attribute__((packed)) { uint64_t mapping; uint32_t tag, size, ref; uint8_t d[64]; } h;
    memset(&h, 0, sizeof h);
    const uint32_t head = (uint32_t)offsetof(__typeof__(h), d);
    if (hv_pvg_lite_task_read(lite, task, at, &h, head + 32)) return;
    /* size is the description's own length (0x38 for a v2 one), after the header */
    if (h.size > 32 && hv_pvg_lite_task_read(lite, task, at, &h, head + MIN(h.size, (uint32_t)sizeof h.d))) {
        memset(h.d + 32, 0, sizeof h.d - 32); /* past the end of the task: keep what the first read had */
    }
    HvObject *surface = [self currentSurface:h.mapping];
    o->on_mapping = h.mapping;
    if (hv_pvg_trace_on()) {
        fprintf(stderr, "trace: mapped texture ref %u tag %#x size %u mapping %llu:", h.ref, h.tag, h.size, h.mapping);
        for (int i = 0; i < 64; i += 4) fprintf(stderr, " %08x", *(uint32_t *)(h.d + i));
        fprintf(stderr, "\n");
    }
    MTLTextureDescriptor *t = h.tag == 0x39 ? descriptor_v2(h.d) : descriptor_v1(h.d);
    if (!surface) surface = [self newSurface:h.mapping];
    if (!surface) return;
    t.storageMode = MTLStorageModeShared;
    set_framebuffer_only(t, NO);
    t.usage |= MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    /* Metal aborts on a swizzled render target, and a surface is always drawn into here: views over it
       (tags 7/8/0x1b) can still swizzle. */
    MTLTextureSwizzleChannels sw = t.swizzle;
    if (sw.red != MTLTextureSwizzleRed || sw.green != MTLTextureSwizzleGreen || sw.blue != MTLTextureSwizzleBlue || sw.alpha != MTLTextureSwizzleAlpha) {
        static int told;
        if (told++ < 3) fprintf(stderr, "hengevm: pvg-metal: surface %llu asked for swizzle %u %u %u %u; drawing it unswizzled\n", h.mapping, sw.red, sw.green, sw.blue, sw.alpha);
        t.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    }
    o->surface = surface;
    /* The plane the texture is over, after the description in the guest's record (PGSerializedTextureDescriptor
       then plane and rotation, 16 bits each: record +0x24 for v1, +0x2c for v2, the record starting at ref).
       macOS draws video and Safari's page tiles one plane at a time (R8 luma, RG8 chroma, R8 alpha): every view
       made over plane 0 left plane 1 empty, so chroma read back as zero (all green) and alpha as zero (blank pages). */
    uint16_t plane;
    memcpy(&plane, h.d + (h.tag == 0x39 ? 0x28 : 0x20), 2);
    static int plane0 = -1; /* HV_PVG_PLANE0 (testing): every view on plane 0, as before this was read */
    if (plane0 < 0) plane0 = getenv("HV_PVG_PLANE0") != NULL;
    if (plane0) plane = 0;
    if(surface->planar_entry && surface->planar_entry->shared_pages){
        id<MTLBuffer> buffer=surface->object;
        if(plane<surface->plane_count && pixel_bytes(t.pixelFormat) && t.textureType==MTLTextureType2D &&
           t.mipmapLevelCount==1 && t.arrayLength==1 && t.sampleCount==1 &&
           surface->plane_from[plane]<=UINT64_MAX-surface->first &&
           linear_texture_fits(device,t,surface->first+surface->plane_from[plane],surface->plane_row[plane],buffer.length))
            o->object=[buffer newTextureWithDescriptor:t offset:surface->first+surface->plane_from[plane] bytesPerRow:surface->plane_row[plane]];
        if(!o->object){
            [self complain:@"unsupported guest-backed planar view; allocation backing retained (HV_PVG_PLANAR_COPY=1 selects reference path)"];
            t.storageMode=MTLStorageModePrivate;o->object=[device newTextureWithDescriptor:t];
        }
        if(o->object)objc_setAssociatedObject(o->object,"henge.planar.owner",surface->planar_entry,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(!plane)mapped_textures[@(h.mapping)]=o->object;
        return;
    }
    if (surface->iosurface && plane >= IOSurfaceGetPlaneCount(surface->iosurface)) {
        [self complain:[NSString stringWithFormat:@"surface %llu: texture on plane %u of %zu; using plane 0", h.mapping, plane,
                        IOSurfaceGetPlaneCount(surface->iosurface)]];
        plane = 0;
    }
    if (plane) {
        static int told;
        if (told++ < 8) fprintf(stderr, "hengevm: pvg-metal: surface %llu: texture %lux%lu format %lu on plane %u\n", h.mapping,
                                (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, plane);
    }
    if (surface->iosurface) {
        o->object = [device newTextureWithDescriptor:t iosurface:surface->iosurface plane:plane];
        if (!o->object) { /* video formats cannot be drawn into */
            t.usage = MTLTextureUsageShaderRead;
            o->object = [device newTextureWithDescriptor:t iosurface:surface->iosurface plane:plane];
        }
    }
    else if (linear_texture_fits(device, t, surface->first, surface->row, ((id<MTLBuffer>)surface->object).length))
        o->object = [(id<MTLBuffer>)surface->object newTextureWithDescriptor:t offset:surface->first bytesPerRow:surface->row];
    if (!o->object) {
        [self complain:[NSString stringWithFormat:@"surface %llu: format %lu row %llu not possible", h.mapping, (unsigned long)t.pixelFormat, surface->row]];
        t.storageMode = MTLStorageModePrivate;
        o->object = [device newTextureWithDescriptor:t]; /* something to bind: it stays empty */
    }
    if(o->object && surface->planar_entry)objc_setAssociatedObject(o->object,"henge.planar.owner",surface->planar_entry,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!plane) mapped_textures[@(h.mapping)] = o->object;
}

- (HvObject *)object:(uint32_t)ref task:(uint32_t)task {
    if (!ref) return nil;
    unsigned slot = batch_cache ? hv_gpu_epoch_slot(task, ref) : 0;
    if (batch_cache && hv_gpu_epoch_match(object_keys[slot], current_epoch, task, ref) && object_values[slot]) {
        object_hits++; return object_values[slot];
    }
    if (batch_cache) object_reads++;
    uint64_t list = hv_pvg_lite_task_objects(lite, task);
    uint32_t e[3];
    if (!list || hv_pvg_lite_task_read(lite, task, list + (uint64_t)ref * 12, e, 12)) return nil;
    NSMutableDictionary *objs = tasks[@(task)];
    if (!objs) tasks[@(task)] = objs = [NSMutableDictionary new];
    HvObject *o = objs[@(ref)];
    if (o && !memcmp(o->entry, e, 12)) {
        /* macOS 14's driver names a surface before it writes the surface's description: try again a while.
           And it reuses surface ids: a texture over a surface that has since been replaced is made again. */
        BOOL replaced = o->object && (e[0] & 0xff) == OBJ_MAPPED_TEXTURE && hv_pvg_lite_old_driver(lite) &&
                        o->surface != [self currentSurface:o->on_mapping];
        if (replaced) o->retries = 0;
        if ((!o->object || replaced) && (e[0] & 0xff) == OBJ_MAPPED_TEXTURE && o->retries < 600) {
            uint32_t tries = o->retries + 1;
            o = nil;
            HvObject *again = [HvObject new];
            memcpy(again->entry, e, 12);
            again->retries = tries;
            objs[@(ref)] = again;
            uint64_t at = (uint64_t)e[2] << 32 | e[1];
            [self makeMappedTexture:again at:at task:task];
            static int told;
            if (again->object && told++ < 30) fprintf(stderr, "hengevm: pvg-metal: task %u ref %u: texture made on try %u%s\n", task, ref, tries, replaced ? " (surface replaced)" : "");
            return again;
        }
        if (!o->follows) {
            if (batch_cache && current_epoch && o->object && ((e[0] & 0xff) == OBJ_FUNCTION || (e[0] & 0xff) == OBJ_SERIALIZED)) {
                object_keys[slot] = (struct HvGpuEpochKey){current_epoch,task,ref}; object_values[slot] = o;
            }
            return o;
        }
        if (o->follows->mapped) refresh_pages(self, task, o->follows);
        if (o->follows->generation == o->follows_generation) return o;
    }
    o = [HvObject new];
    memcpy(o->entry, e, 12);
    objs[@(ref)] = o;
    uint32_t type = e[0] & 0xff, size = e[0] >> 8;
    uint64_t at = (uint64_t)e[2] << 32 | e[1];
    switch (type) {
    case OBJ_BUFFER: [self makeBuffer:o at:at task:task]; break;
    case OBJ_TEXTURE: case 3: /* 3: macOS 13's driver, the same {length, page, layout, mips, record} entry */
        [self makeTexture:o at:at size:size task:task]; break;
    case OBJ_FUNCTION: o->object = [self makeFunction:at task:task]; break;
    case OBJ_SERIALIZED: o->object = [self makeSerialized:at length:size task:task]; break;
    case OBJ_LINEAR_TEXTURE: case 9: [self makeLinearTexture:o at:at size:size task:task]; break;
    case 13: [self makeHeap:o at:at task:task]; break;
    case 14: [self makeHeapBuffer:o at:at task:task]; break;
    case 19: /* macOS 27: a buffer, with the same {length, page, flags} entry as type 1 (16 KB ones seen). The guest
                has object info (tags 450...) written into these, so leaving them out broke its argument buffers:
                black layers, and "info 450 ... no buffer" over and over */
        [self makeBuffer:o at:at task:task];
        break;
    case 0: break; /* an empty slot */
    case OBJ_MAPPED_TEXTURE: [self makeMappedTexture:o at:at task:task]; break;
    default: {
        uint32_t w[24] = {0};
        hv_pvg_lite_task_read(lite, task, at, w, sizeof w);
        NSMutableString *m = [NSMutableString stringWithFormat:@"object type %u size %u:", type, size];
        for (int i = 0; i < 24; i++) [m appendFormat:@" %08x", w[i]];
        [self complain:m];
        break;
    }
    }
    if (batch_cache && current_epoch && o->object && (type == OBJ_FUNCTION || type == OBJ_SERIALIZED)) {
        object_keys[slot] = (struct HvGpuEpochKey){current_epoch,task,ref}; object_values[slot] = o;
    }
    return o;
}

- (id)get:(uint32_t)ref task:(uint32_t)task {
    HvObject *o = [self object:ref task:task];
    return o ? o->object : nil;
}

/* The object's guest memory as a buffer, once it has some. */
static id<MTLBuffer> guest_copy(HvReplay *r, uint32_t task, HvObject *o) {
    if (!o->vpage || !o->length) return nil;
    if (!o->mapped && !map_pages(r, task, o)) return nil;
    refresh_pages(r, task, o);
    if (!o->guest_copy) o->guest_copy = buffer_over_mapping(r, o);
    return o->guest_copy;
}

static BOOL has_guest_pages(HvObject *o) {
    uint64_t n = (o->length + 0x3fff) >> 14;
    for (uint64_t i = 0; o->pages && i < n; i++)
        if (o->pages[i]) return YES;
    return NO;
}

/* Between guest memory and the GPU's own copy, in the layout the guest was told. */
- (BOOL)page:(HvObject *)o toGuest:(BOOL)down task:(uint32_t)task blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb {
    id<MTLBuffer> copy = guest_copy(self, task, o);
    if (!copy || !has_guest_pages(o)) return NO;
    uint64_t pages = (o->length + 0x3fff) >> 14;
    for (uint64_t i = 0; i < pages; i++) if (!o->pages[i]) return NO;
    if (o->heap_whole) {
        if (!o->heap_whole.length || copy.length < o->heap_whole.length) return NO;
        if (!*blit) *blit = [cb blitCommandEncoder];
        NSUInteger bytes = MIN(copy.length, o->heap_whole.length);
        if (down) [*blit copyFromBuffer:o->heap_whole sourceOffset:0 toBuffer:copy destinationOffset:0 size:bytes];
        else [*blit copyFromBuffer:copy sourceOffset:0 toBuffer:o->heap_whole destinationOffset:0 size:bytes];
        return *blit != nil;
    }
    id<MTLTexture> tex = o->object;
    if (!tex || !o->tex_layout || tex.sampleCount > 1 || tex.isFramebufferOnly) return NO;
    NSUInteger faces = tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray ? 6 : 1;
    if (!o->tex_slices || !o->tex_mips || o->tex_mips > tex.mipmapLevelCount || o->tex_slices > tex.arrayLength) return NO;
    /* Validate every mip before enqueueing any copy; only the second pass encodes. */
    for (unsigned pass = 0; pass < 2; pass++)
    for (uint64_t s = 0; s < (uint64_t)o->tex_slices * faces; s++)
        for (uint32_t m = 0; m < o->tex_mips; m++) {
            const uint8_t *mip = o->tex_layout + m * 36;
            uint64_t off, row;
            uint32_t w, h, d;
            memcpy(&off, mip, 8), memcpy(&row, mip + 0x10, 8), memcpy(&w, mip + 0x18, 4), memcpy(&h, mip + 0x1c, 4), memcpy(&d, mip + 0x20, 4);
            uint32_t bh = o->tex_block_h ? o->tex_block_h : 1;
            uint64_t from, image;
            if (!w || !hv_gpu_copy_range(o->tex_base, o->tex_stride, s, off, row, h, d, bh,
                                         MIN(o->length, copy.length), &from, &image)) return NO;
            if (!pass) continue;
            if (!*blit) *blit = [cb blitCommandEncoder];
            if (!*blit) return NO;
            if (down)
                [*blit copyFromTexture:tex sourceSlice:s sourceLevel:m sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, d)
                              toBuffer:copy destinationOffset:from destinationBytesPerRow:row destinationBytesPerImage:image];
            else
                [*blit copyFromBuffer:copy sourceOffset:from sourceBytesPerRow:row sourceBytesPerImage:image
                           sourceSize:MTLSizeMake(w, h, d) toTexture:tex destinationSlice:s destinationLevel:m destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
    return YES;
}

/* The guest asks to see what the GPU made: {task, count, refs}. */
- (void)synchronize:(const uint32_t *)a length:(uint32_t)n {
    if (n < 8) return;
    uint32_t task = a[0], count = a[1];
    if (n < 8 + count * 4ull) return;
    NSMutableDictionary *objs = tasks[@(task)];
    id<MTLCommandBuffer> cb = nil;
    id<MTLBlitCommandEncoder> blit = nil;
    for (uint32_t i = 0; i < count; i++) {
        HvObject *o = objs[@(a[2 + i])];
        if (!o || !o->guest_backed || !o->host_valid) continue;
        if (!cb) cb = [queue commandBuffer];
        if ([self page:o toGuest:YES task:task blit:&blit commandBuffer:cb]) o->guest_stale = NO;
    }
    [blit endEncoding];
    if (cb) {
        [self commit:cb channel:0 stamp:0 complete:NO];
        synced++;
    }
}

/* {task, count, {ref, host invalid, host valid, guest invalid, guest valid}}. */
- (void)invalidate:(const uint32_t *)a length:(uint32_t)n {
    if (n < 8 || n < 8 + a[1] * 8ull) return;
    NSMutableDictionary *objs = tasks[@(a[0])];
    const uint8_t *e = (const uint8_t *)(a + 2);
    for (uint32_t i = 0; i < a[1]; i++, e += 8) {
        HvObject *o = objs[@(*(const uint32_t *)e)];
        if (!o) continue;
        if (e[6]) o->guest_stale = YES;
        if (e[7]) o->guest_stale = NO;
        if (e[4]) o->host_valid = NO;
        if (e[5]) o->host_valid = YES;
    }
}

/* A record's bytes, as a pointer into the buffer's private copy. */
typedef struct {
    const uint8_t *p;
    uint32_t size;
} Rec;

#define U32(off) (*(const uint32_t *)(r.p + (off)))
#define U16(off) (*(const uint16_t *)(r.p + (off)))
#define U64(off) ({ uint64_t _v; memcpy(&_v, r.p + (off), 8); _v; })

- (id<MTLRenderCommandEncoder>)beginPass:(Rec)r task:(uint32_t)task commandBuffer:(id<MTLCommandBuffer>)cb {
    MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
#define ATTACH(a, o)                                                 \
    do {                                                             \
        a.texture = [self get:U32((o)) task:task];                   \
        a.resolveTexture = [self get:U32((o) + 4) task:task];        \
        a.level = U16((o) + 8), a.slice = U16((o) + 10);             \
        a.depthPlane = U16((o) + 12), a.resolveLevel = U16((o) + 14); \
        a.resolveSlice = U16((o) + 16), a.resolveDepthPlane = U16((o) + 18); \
        a.loadAction = (MTLLoadAction)U16((o) + 20);                 \
        a.storeAction = (MTLStoreAction)U16((o) + 22);               \
        a.storeActionOptions = U16((o) + 24);                        \
    } while (0)
    ATTACH(d.depthAttachment, 0);
    double clear_depth;
    memcpy(&clear_depth, r.p + 0x1c, 8);
    d.depthAttachment.clearDepth = clear_depth;
    ATTACH(d.stencilAttachment, 0x28);
    d.stencilAttachment.clearStencil = U32(0x44);
    for (int i = 0; i < 8; i++) {
        uint32_t o = 0x4c + (uint32_t)i * 0x3c;
        if (o + 0x3c > r.size) break;
        MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
        ATTACH(c, o);
        double col[4];
        memcpy(col, r.p + o + 0x1c, sizeof col);
        c.clearColor = MTLClearColorMake(col[0], col[1], col[2], col[3]);
    }
    /* Memoryless and resolve store actions want the matching textures; a pass with none stays dontCare. */
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
        if (!c.texture) c.storeAction = MTLStoreActionDontCare, c.loadAction = MTLLoadActionDontCare;
        else if (!c.resolveTexture && (c.storeAction == MTLStoreActionMultisampleResolve || c.storeAction == MTLStoreActionStoreAndMultisampleResolve))
            c.storeAction = MTLStoreActionStore;
    }
    if (!d.depthAttachment.texture) d.depthAttachment.loadAction = MTLLoadActionDontCare, d.depthAttachment.storeAction = MTLStoreActionDontCare;
    if (!d.stencilAttachment.texture) d.stencilAttachment.loadAction = MTLLoadActionDontCare, d.stencilAttachment.storeAction = MTLStoreActionDontCare;
    /* After the attachments: the visibility buffer and the render target's size. */
    if (r.size >= 0x248) {
        if (U32(0x22c)) d.visibilityResultBuffer = [self get:U32(0x22c) task:task];
        uint64_t layers = U64(0x230), rw = U64(0x238), rh = U64(0x240);
        if (layers) d.renderTargetArrayLength = (NSUInteger)layers;
        if (rw) d.renderTargetWidth = (NSUInteger)rw;
        if (rh) d.renderTargetHeight = (NSUInteger)rh;
    }
    /* What came before the pass itself. */
    if (pre_raster_samples) d.defaultRasterSampleCount = pre_raster_samples;
    if (pre_imageblock) d.imageblockSampleLength = pre_imageblock;
    if (pre_threadgroup) d.threadgroupMemoryLength = pre_threadgroup;
    if (pre_tile_w) d.tileWidth = pre_tile_w, d.tileHeight = pre_tile_h;
    {   /* HV_PVG_PASSDUMP=N: the first N render pass records, raw and as read (for a guest driver whose layout differs) */
        static int left = -1;
        if (left < 0) left = getenv("HV_PVG_PASSDUMP") ? atoi(getenv("HV_PVG_PASSDUMP")) : 0;
        if (left > 0) {
            left--;
            fprintf(stderr, "passdump: size 0x%x samples %lu imageblock %lu threadgroup %lu tile %lux%lu layers %lu rt %lux%lu\n", r.size,
                    (unsigned long)d.defaultRasterSampleCount, (unsigned long)d.imageblockSampleLength, (unsigned long)d.threadgroupMemoryLength,
                    (unsigned long)d.tileWidth, (unsigned long)d.tileHeight, (unsigned long)d.renderTargetArrayLength,
                    (unsigned long)d.renderTargetWidth, (unsigned long)d.renderTargetHeight);
            for (int i = -2; i < 8; i++) {
                MTLRenderPassAttachmentDescriptor *a = i == -2 ? (MTLRenderPassAttachmentDescriptor *)d.depthAttachment
                                                      : i == -1 ? (MTLRenderPassAttachmentDescriptor *)d.stencilAttachment : d.colorAttachments[i];
                if (!a.texture) continue;
                fprintf(stderr, "passdump:   %s%d tex %lux%lu fmt %lu samples %lu type %lu usage %lu storage %lu level %lu slice %lu load %lu store %lu opts %lu resolve %s\n",
                        i == -2 ? "depth" : i == -1 ? "stencil" : "c", i < 0 ? 0 : i, (unsigned long)a.texture.width, (unsigned long)a.texture.height,
                        (unsigned long)a.texture.pixelFormat, (unsigned long)a.texture.sampleCount, (unsigned long)a.texture.textureType,
                        (unsigned long)a.texture.usage, (unsigned long)a.texture.storageMode, (unsigned long)a.level, (unsigned long)a.slice,
                        (unsigned long)a.loadAction, (unsigned long)a.storeAction, (unsigned long)a.storeActionOptions, a.resolveTexture ? "yes" : "no");
            }
            for (int i = -2; i < 8; i++) { /* a named attachment Henge has no texture for: its object table entry */
                uint32_t o = i == -2 ? 0 : i == -1 ? 0x28 : 0x4c + (uint32_t)i * 0x3c, ref = o + 4 <= r.size ? U32(o) : 0;
                if (!ref || [self get:ref task:task]) continue;
                uint64_t list = hv_pvg_lite_task_objects(lite, task);
                uint32_t e[3] = {0}, w[24] = {0};
                if (list) hv_pvg_lite_task_read(lite, task, list + (uint64_t)ref * 12, e, 12);
                uint64_t at = (uint64_t)e[2] << 32 | e[1];
                if (at) hv_pvg_lite_task_read(lite, task, at, w, sizeof w);
                fprintf(stderr, "passdump:   missing ref %u (slot %d): type %u size %u at 0x%llx:", ref, i, e[0] & 0xff, e[0] >> 8, (unsigned long long)at);
                for (int k = 0; k < 24; k++) fprintf(stderr, " %08x", w[k]);
                fprintf(stderr, "\n");
            }
            for (uint32_t o = 0; o < r.size && o < 0x260; o += 32) {
                fprintf(stderr, "passdump:   %03x:", o);
                for (uint32_t k = o; k < o + 32 && k < r.size; k += 4) fprintf(stderr, " %08x", U32(k));
                fprintf(stderr, "\n");
            }
        }
    }
    pre_raster_samples = pre_imageblock = pre_threadgroup = pre_tile_w = pre_tile_h = 0;
    /* An attachment the guest names but Henge never made (a texture from a record it doesn't know) leaves a pass with
       no attachments; with a render size and no sample count, the GPU driver aborts the whole app building it. Skip it. */
    int named = 0, made = 0;
    for (int i = -2; i < 8; i++) {
        uint32_t o = i == -2 ? 0 : i == -1 ? 0x28 : 0x4c + (uint32_t)i * 0x3c;
        if (o + 4 > r.size || !U32(o)) continue;
        named++;
        made += (i == -2 ? d.depthAttachment.texture : i == -1 ? d.stencilAttachment.texture : d.colorAttachments[i].texture) != nil;
    }
    if (named && made < named) {
        static int told;
        if (told++ < 20) fprintf(stderr, "hengevm: pvg-metal: pass skipped: %d of its %d attachments were never made\n", named - made, named);
        return nil;
    }
    if (!named && !d.defaultRasterSampleCount) d.defaultRasterSampleCount = 1;
    if (tracing) {
        id<MTLTexture> c0 = d.colorAttachments[0].texture;
        MTLClearColor cc = d.colorAttachments[0].clearColor;
        HvObject *co = [self object:U32(0x4c) task:task];
        fprintf(stderr, "trace: pass c0 ref %u %lux%lu fmt %lu load %lu store %lu clear %.2f %.2f %.2f %.2f surface %s heap %d\n", U32(0x4c), (unsigned long)c0.width, (unsigned long)c0.height, (unsigned long)c0.pixelFormat, (unsigned long)d.colorAttachments[0].loadAction, (unsigned long)d.colorAttachments[0].storeAction, cc.red, cc.green, cc.blue, cc.alpha, co && co->surface ? "yes" : "no", c0.heap != nil);
    }
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:d];
    if (!e) {
        if(@available(macOS 26.0,iOS 26.0,*))if([cb isKindOfClass:HvMetal4Buffer.class])[NSException raise:@"HengeMetal4Fallback" format:@"render pass unavailable"];
        NSMutableString *m = [NSMutableString stringWithString:@"no render encoder:"];
        for (int i = 0; i < 8; i++) {
            MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
            uint32_t ref = U32(0x4c + (uint32_t)i * 0x3c);
            if (ref) [m appendFormat:@" c%d ref %u %s %lux%lu fmt %lu load %lu store %lu usage %lu", i, ref, c.texture ? "ok" : "MISSING", (unsigned long)c.texture.width, (unsigned long)c.texture.height, (unsigned long)c.texture.pixelFormat, (unsigned long)c.loadAction, (unsigned long)c.storeAction, (unsigned long)c.texture.usage];
        }
        [m appendFormat:@" depth ref %u stencil ref %u", U32(0), U32(0x28)];
        [self complain:m];
    }
    return e;
}

/* Resolve objects before comparing. Metal command buffers retain every set
   resource through GPU completion, so a host identity cannot be recycled within
   this encoder. The cache is only a proof of the last setter in each family. */
static BOOL binding_objects(HvBindingCache *cache,unsigned family,uint32_t tag,
                           const void *bytes,size_t length,id __strong const *objects,size_t count) {
    uint8_t key[HV_BIND_KEY_BYTES];
    size_t head=sizeof tag + count*sizeof(uintptr_t);
    if(count>128 || head>sizeof key || length>sizeof key-head) {
        return hv_binding_update(cache,family,NULL,0);
    }
    memcpy(key,&tag,sizeof tag);
    for(size_t i=0;i<count;i++) {
        uintptr_t value=(uintptr_t)(__bridge void *)objects[i];
        memcpy(key+sizeof tag+i*sizeof value,&value,sizeof value);
    }
    if(length)memcpy(key+head,bytes,length);
    return hv_binding_update(cache,family,key,head+length);
}

/* One serialized call. Tags are the guest's. */
- (void)useHeaps:(const uint32_t *)refs count:(uint32_t)n task:(uint32_t)task encoder:(id)e stages:(int)stages {
    id<MTLHeap> __unsafe_unretained list[64];
    NSMutableArray *keep = [NSMutableArray new];
    uint32_t have = 0;
    for (uint32_t i = 0; i < n && have < 64; i++) {
        id heap = [self get:refs[i] task:task];
        if (!heap) continue;
        [keep addObject:heap];
        list[have++] = heap;
    }
    if (!have) return;
    if (stages >= 0) [(id<MTLRenderCommandEncoder>)e useHeaps:list count:have stages:(MTLRenderStages)stages];
    else if ([e conformsToProtocol:@protocol(MTLRenderCommandEncoder)]) [(id<MTLRenderCommandEncoder>)e useHeaps:list count:have];
    else [(id<MTLComputeCommandEncoder>)e useHeaps:list count:have];
}

- (void)render:(id<MTLRenderCommandEncoder>)e tag:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    BOOL draw = tag <= 19 || tag == 28 || tag == 29 || tag == 155 || tag == 162;
    if (!pipeline_set && draw) return;
    if (tracing && draw) fprintf(stderr, "trace:  draw tag %u\n", tag);
    switch (tag) {
    case 102: case 103: case 105: case 106: case 120: case 121:
        /* Focused PR117 port: honour guest final store/discard/resolve actions
           before ending this same encoder; no alternate shader/replay path. */
        if (!hv_pvg_apply_store_action(e,tag,r.p,r.size))
            [self complain:[NSString stringWithFormat:@"invalid store action tag %u (%u bytes)",tag,r.size]];
        break;
    case 24: { /* {fence, stages} */
        id f = [self get:U32(0) task:task];
        if (f) [e updateFence:f afterStages:(MTLRenderStages)(U32(4) & 0xffff)];
        break;
    }
    case 25: {
        id f = [self get:U32(0) task:task];
        if (f) [e waitForFence:f beforeStages:(MTLRenderStages)(U32(4) & 0xffff)];
        break;
    }
    case 27: /* {count, stages}, the heaps */
        if (r.size >= 8 + U32(0) * 4ull) [self useHeaps:(const uint32_t *)(r.p + 8) count:U32(0) task:task encoder:e stages:U32(4) & 0xffff];
        break;
    case 134: /* {count}, the heaps */
        if (r.size >= 4 + U32(0) * 4ull) [self useHeaps:(const uint32_t *)(r.p + 4) count:U32(0) task:task encoder:e stages:-1];
        break;
    case 116: { /* Metal crashes on a missing pipeline, and on drawing without one */
        id state = [self get:U32(0) task:task];
        id resolved[]={state};
        if (state && binding_objects(&bindings,HV_BIND_PIPELINE,tag,r.p,r.size,resolved,1)) [e setRenderPipelineState:state];
        pipeline_set = state != nil;
        if (tracing) fprintf(stderr, "trace:  pipeline %u %s\n", U32(0), [objc_getAssociatedObject(state, "hvname") UTF8String]);
        break;
    }
    case 125: case 110: case 157: { /* vertex, fragment, tile buffers: {index, count}, {ref, offset}... */
        uint32_t index = U32(0), count = U32(4);
        if (count > 31) break;
        __unsafe_unretained id<MTLBuffer> buffers[31];
        id strong[31];
        NSUInteger offsets[31];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 12) task:task];
            buffers[i] = strong[i];
            offsets[i] = (NSUInteger)U64(12 + i * 12);
        }
        NSRange range = NSMakeRange(index, count);
        if (tracing) for (uint32_t i = 0; i < count; i++) { /* m4 fork: what the shaders are given */
            id<MTLBuffer> bb = strong[i];
            fprintf(stderr, "trace:  %s buf %u ref %u off %lu len %lu:", tag == 125 ? "vtx" : tag == 110 ? "frag" : "tile", index + i, U32(8 + i * 12),
                    (unsigned long)offsets[i], (unsigned long)bb.length);
            if (bb && bb.storageMode != MTLStorageModePrivate && offsets[i] < bb.length) {
                const float *f = (const float *)((const uint8_t *)bb.contents + offsets[i]);
                NSUInteger nf = MIN((bb.length - offsets[i]) / 4, (NSUInteger)96);
                for (NSUInteger k = 0; k < nf; k++) fprintf(stderr, " %g", f[k]);
            }
            fprintf(stderr, "\n");
        }
        unsigned family=tag==125?HV_BIND_VERTEX_BUFFER:tag==110?HV_BIND_FRAGMENT_BUFFER:HV_BIND_TILE_BUFFER;
        if(binding_objects(&bindings,family,tag,r.p,r.size,strong,count)) {
            if (tag == 125) [e setVertexBuffers:buffers offsets:offsets withRange:range];
            else if (tag == 110) [e setFragmentBuffers:buffers offsets:offsets withRange:range];
            else [e setTileBuffers:buffers offsets:offsets withRange:range];
        }
        break;
    }
    case 126: if(binding_objects(&bindings,HV_BIND_VERTEX_BUFFER,tag,r.p,r.size,NULL,0)) [e setVertexBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)]; break;
    case 111: if(binding_objects(&bindings,HV_BIND_FRAGMENT_BUFFER,tag,r.p,r.size,NULL,0)) [e setFragmentBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)]; break;
    case 114: case 161: { /* fragment, tile textures */
        uint32_t index = U32(0), count = U32(4);
        if (count > 128) break;
        __unsafe_unretained id<MTLTexture> items[128];
        id strong[128];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if (tracing) for (uint32_t i = 0; i < count; i++) {
            id<MTLTexture> x = strong[i];
            HvObject *xo = [self object:U32(8 + i * 4) task:task];
            fprintf(stderr, "trace:  tex %u ref %u %lux%lu fmt %lu type %u swz %d%d%d%d surface %s heap %d valid %d\n", index + i, U32(8 + i * 4), (unsigned long)x.width, (unsigned long)x.height, (unsigned long)x.pixelFormat, xo ? xo->entry[0] & 0xff : 0, x.swizzle.red, x.swizzle.green, x.swizzle.blue, x.swizzle.alpha, xo && xo->surface ? "yes" : "no", x.heap != nil, xo ? xo->host_valid : 0);
        }
        if(binding_objects(&bindings,tag==114?HV_BIND_FRAGMENT_TEXTURE:HV_BIND_TILE_TEXTURE,tag,r.p,r.size,strong,count)) {
            if (tag == 114) [e setFragmentTextures:items withRange:NSMakeRange(index, count)];
            else [e setTileTextures:items withRange:NSMakeRange(index, count)];
        }
        break;
    }
    case 112: { /* fragment samplers */
        uint32_t index = U32(0), count = U32(4);
        if (count > 16) break;
        __unsafe_unretained id<MTLSamplerState> items[16];
        id strong[16];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if(binding_objects(&bindings,HV_BIND_FRAGMENT_SAMPLER,tag,r.p,r.size,strong,count)) [e setFragmentSamplerStates:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 117: {
        MTLScissorRect s;
        memcpy(&s, r.p, sizeof s);
        if(binding_objects(&bindings,HV_BIND_SCISSOR,tag,r.p,r.size,NULL,0)) [e setScissorRect:s];
        if (tracing) fprintf(stderr, "trace:  scissor %lu %lu %lu %lu\n", (unsigned long)s.x, (unsigned long)s.y, (unsigned long)s.width, (unsigned long)s.height);
        break;
    }
    case 130: {
        MTLViewport v;
        memcpy(&v, r.p, sizeof v);
        if(binding_objects(&bindings,HV_BIND_VIEWPORT,tag,r.p,r.size,NULL,0)) [e setViewport:v];
        break;
    }
    case 122: { /* {ref, offset, stride} */
        id<MTLBuffer> b = [self get:U32(0) task:task];
        [e setTessellationFactorBuffer:b offset:(NSUInteger)U64(4) instanceStride:(NSUInteger)U64(12)];
        tess_factors = b != nil;
        break;
    }
    case 123: {
        float f;
        memcpy(&f, r.p, 4);
        [e setTessellationFactorScale:f];
        break;
    }
    case 104: {
        id state = [self get:U32(0) task:task];
        id resolved[]={state};
        if(binding_objects(&bindings,HV_BIND_DEPTH,tag,r.p,r.size,resolved,1)) [e setDepthStencilState:state];
        break;
    }
    case 107: if(binding_objects(&bindings,HV_BIND_CULL,tag,r.p,r.size,NULL,0)) [e setCullMode:(MTLCullMode)U32(0)]; break;
    case 108: {
        float f[3];
        memcpy(f, r.p, sizeof f);
        if(binding_objects(&bindings,HV_BIND_BIAS,tag,r.p,r.size,NULL,0)) [e setDepthBias:f[0] slopeScale:f[1] clamp:f[2]];
        break;
    }
    case 109: if(binding_objects(&bindings,HV_BIND_CLIP,tag,r.p,r.size,NULL,0)) [e setDepthClipMode:(MTLDepthClipMode)U32(0)]; break;
    case 115: if(binding_objects(&bindings,HV_BIND_WINDING,tag,r.p,r.size,NULL,0)) [e setFrontFacingWinding:(MTLWinding)U32(0)]; break;
    case 124: if(binding_objects(&bindings,HV_BIND_FILL,tag,r.p,r.size,NULL,0)) [e setTriangleFillMode:(MTLTriangleFillMode)U32(0)]; break;
    case 119: if(binding_objects(&bindings,HV_BIND_STENCIL,tag,r.p,r.size,NULL,0)) [e setStencilFrontReferenceValue:U32(0) backReferenceValue:U32(4)]; break;
    case 118: { /* a header, then the rectangles */
        uint32_t head = r.size % sizeof(MTLScissorRect), n = (r.size - head) / sizeof(MTLScissorRect);
        if (n) if(binding_objects(&bindings,HV_BIND_SCISSOR,tag,r.p,r.size,NULL,0)) [e setScissorRects:(const MTLScissorRect *)(r.p + head) count:n];
        break;
    }
    case 131: {
        uint32_t head = r.size % sizeof(MTLViewport), n = (r.size - head) / sizeof(MTLViewport);
        if (n) if(binding_objects(&bindings,HV_BIND_VIEWPORT,tag,r.p,r.size,NULL,0)) [e setViewports:(const MTLViewport *)(r.p + head) count:n];
        break;
    }
    case 129: { /* vertex textures: {index, count}, refs */
        uint32_t index = U32(0), count = U32(4);
        if (count > 128) break;
        __unsafe_unretained id<MTLTexture> items[128];
        id strong[128];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if(binding_objects(&bindings,HV_BIND_VERTEX_TEXTURE,tag,r.p,r.size,strong,count)) [e setVertexTextures:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 127: { /* vertex samplers */
        uint32_t index = U32(0), count = U32(4);
        if (count > 16) break;
        __unsafe_unretained id<MTLSamplerState> items[16];
        id strong[16];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if(binding_objects(&bindings,HV_BIND_VERTEX_SAMPLER,tag,r.p,r.size,strong,count)) [e setVertexSamplerStates:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 113: case 128: { /* samplers with LOD clamps: {index, count}, refs, minimums, maximums */
        uint32_t index = U32(0), count = U32(4);
        if (count > 16 || r.size < 8 + count * 12ull) break;
        __unsafe_unretained id<MTLSamplerState> items[16];
        id strong[16];
        float lo[16], hi[16];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
            memcpy(&lo[i], r.p + 8 + count * 4 + i * 4, 4);
            memcpy(&hi[i], r.p + 8 + count * 8 + i * 4, 4);
        }
        if(binding_objects(&bindings,tag==113?HV_BIND_FRAGMENT_SAMPLER:HV_BIND_VERTEX_SAMPLER,tag,r.p,r.size,strong,count)) {
            if (tag == 113) [e setFragmentSamplerStates:items lodMinClamps:lo lodMaxClamps:hi withRange:NSMakeRange(index, count)];
            else [e setVertexSamplerStates:items lodMinClamps:lo lodMaxClamps:hi withRange:NSMakeRange(index, count)];
        }
        break;
    }
    case 135: case 137: { /* {count, usage}, or {count, usage 16, stages 16}, then the resources */
        uint32_t count = U32(0);
        if (count > 256 || r.size < 8 + count * 4ull) break;
        __unsafe_unretained id<MTLResource> items[256];
        NSMutableArray *keep = [NSMutableArray new];
        uint32_t have = 0;
        for (uint32_t i = 0; i < count; i++) {
            id x = [self get:U32(8 + i * 4) task:task];
            if (!x || [x conformsToProtocol:@protocol(MTLHeap)]) continue;
            [keep addObject:x];
            items[have++] = x;
        }
        if (!have) break;
        if (tag == 135) [e useResources:items count:have usage:(MTLResourceUsage)U32(4)];
        else [e useResources:items count:have usage:(MTLResourceUsage)U16(4) stages:(MTLRenderStages)U16(6)];
        break;
    }
    case 165: { /* vertex buffers with stride: {index, count}, {ref, offset, stride}... */
        uint32_t index = U32(0), count = U32(4);
        if (count > 31 || r.size < 8 + count * 20ull) break;
        __unsafe_unretained id<MTLBuffer> buffers[31];
        id strong[31];
        NSUInteger offsets[31], strides[31];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 20) task:task];
            buffers[i] = strong[i];
            offsets[i] = (NSUInteger)U64(12 + i * 20);
            strides[i] = (NSUInteger)U64(20 + i * 20);
        }
        if(binding_objects(&bindings,HV_BIND_VERTEX_BUFFER,tag,r.p,r.size,strong,count)) [e setVertexBuffers:buffers offsets:offsets attributeStrides:strides withRange:NSMakeRange(index, count)];
        break;
    }
    case 166: if(binding_objects(&bindings,HV_BIND_VERTEX_BUFFER,tag,r.p,r.size,NULL,0)) [e setVertexBufferOffset:(NSUInteger)U64(4) attributeStride:(NSUInteger)U64(12) atIndex:U32(0)]; break;
    case 101: {
        float c[4];
        memcpy(c, r.p, sizeof c);
        if(binding_objects(&bindings,HV_BIND_BLEND,tag,r.p,r.size,NULL,0)) [e setBlendColorRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
        break;
    }
    case 13: { /* {start 16, count 16, index ref, offset 16, instances 16, base instance 16, control points 16} */
        if (!tess_factors) break; /* Metal crashes without a factor buffer */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        [e drawPatches:U16(14) patchStart:U16(0) patchCount:U16(2) patchIndexBuffer:b patchIndexBufferOffset:U16(8) instanceCount:U16(10) baseInstance:U16(12)];
        draws++;
        break;
    }
    case 12: { /* {start 64, count 64, index ref, offset 64, instances 64, base instance 64, control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> b = [self get:U32(16) task:task];
        [e drawPatches:U16(44) patchStart:(NSUInteger)U64(0) patchCount:(NSUInteger)U64(8) patchIndexBuffer:b patchIndexBufferOffset:(NSUInteger)U64(20)
         instanceCount:(NSUInteger)U64(28) baseInstance:(NSUInteger)U64(36)];
        draws++;
        break;
    }
    case 14: { /* {start 64, count 64, patch index ref, offset 64, control point index ref, offset 64, instances 64, base instance 64, control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> patches = [self get:U32(16) task:task], points = [self get:U32(28) task:task];
        if (points) [e drawIndexedPatches:U16(56) patchStart:(NSUInteger)U64(0) patchCount:(NSUInteger)U64(8) patchIndexBuffer:patches patchIndexBufferOffset:(NSUInteger)U64(20)
                  controlPointIndexBuffer:points controlPointIndexBufferOffset:(NSUInteger)U64(32) instanceCount:(NSUInteger)U64(40) baseInstance:(NSUInteger)U64(48)];
        draws++;
        break;
    }
    case 15: { /* {start 16, count 16, patch index ref, offset 16, control point index ref, offset 16, instances 16, base instance 16, control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> patches = [self get:U32(4) task:task], points = [self get:U32(10) task:task];
        if (points) [e drawIndexedPatches:U16(20) patchStart:U16(0) patchCount:U16(2) patchIndexBuffer:patches patchIndexBufferOffset:U16(8)
                  controlPointIndexBuffer:points controlPointIndexBufferOffset:U16(14) instanceCount:U16(16) baseInstance:U16(18)];
        draws++;
        break;
    }
    case 18: { /* {patch index ref, indirect ref, patch index offset 64, indirect offset 64, control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> patches = [self get:U32(0) task:task], indirect = [self get:U32(4) task:task];
        if (indirect) [e drawPatches:U16(24) patchIndexBuffer:patches patchIndexBufferOffset:(NSUInteger)U64(8) indirectBuffer:indirect indirectBufferOffset:(NSUInteger)U64(16)];
        draws++;
        break;
    }
    case 19: { /* {patch index ref, control point index ref, indirect ref, then their three offsets, 64, and control points 16} */
        if (!tess_factors) break;
        id<MTLBuffer> patches = [self get:U32(0) task:task], points = [self get:U32(4) task:task], indirect = [self get:U32(8) task:task];
        if (points && indirect) [e drawIndexedPatches:U16(36) patchIndexBuffer:patches patchIndexBufferOffset:(NSUInteger)U64(12) controlPointIndexBuffer:points
                                controlPointIndexBufferOffset:(NSUInteger)U64(20) indirectBuffer:indirect indirectBufferOffset:(NSUInteger)U64(28)];
        draws++;
        break;
    }
    case 1: /* {primitive, start 16, count 16} */
        [e drawPrimitives:(MTLPrimitiveType)U32(0) vertexStart:U16(4) vertexCount:U16(6)];
        draws++;
        break;
    case 3: /* {start, count, instances, primitive} */
        [e drawPrimitives:(MTLPrimitiveType)U16(6) vertexStart:U16(0) vertexCount:U16(2) instanceCount:U16(4)];
        draws++;
        break;
    case 7: { /* {primitive, index type, ref, count, offset} */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:U16(8) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:U16(10)];
        draws++;
        break;
    }
    case 6: {
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:(NSUInteger)U64(8) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:(NSUInteger)U64(16)];
        draws++;
        break;
    }
    case 9: { /* {primitive, index type, ref, count 16, offset 16, instances 16} */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:U16(8) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:U16(10) instanceCount:U16(12)];
        draws++;
        break;
    }
    case 8: { /* {primitive, index type, ref, count 64, offset 64, instances 64} */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:(NSUInteger)U64(8) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:(NSUInteger)U64(16) instanceCount:(NSUInteger)U64(24)];
        draws++;
        break;
    }
    case 0: /* {primitive 32, start 64, count 64} */
        [e drawPrimitives:(MTLPrimitiveType)U32(0) vertexStart:(NSUInteger)U64(4) vertexCount:(NSUInteger)U64(12)];
        draws++;
        break;
    case 2: /* {start 64, count 64, instances 64, primitive} */
        [e drawPrimitives:(MTLPrimitiveType)U16(24) vertexStart:(NSUInteger)U64(0) vertexCount:(NSUInteger)U64(8) instanceCount:(NSUInteger)U64(16)];
        draws++;
        break;
    case 4: /* {start 64, count 64, instances 64, base instance 64, primitive} */
        [e drawPrimitives:(MTLPrimitiveType)U16(32) vertexStart:(NSUInteger)U64(0) vertexCount:(NSUInteger)U64(8) instanceCount:(NSUInteger)U64(16) baseInstance:(NSUInteger)U64(24)];
        draws++;
        break;
    case 5: /* {start, count, instances, base instance, primitive}, all 16 */
        [e drawPrimitives:(MTLPrimitiveType)U16(8) vertexStart:U16(0) vertexCount:U16(2) instanceCount:U16(4) baseInstance:U16(6)];
        draws++;
        break;
    case 10: case 28: { /* {primitive, index type, ref, offset 64, count 64, instances 64, base vertex 64, base instance 64} */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:(NSUInteger)U64(16) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:(NSUInteger)U64(8)
                          instanceCount:(NSUInteger)U64(24) baseVertex:(NSInteger)U64(32) baseInstance:(NSUInteger)U64(40)];
        draws++;
        break;
    }
    case 11: case 29: { /* {primitive, index type, ref, offset 16, count 16, instances 16, base vertex 16, base instance 16}; 29's base vertex can be negative */
        id<MTLBuffer> b = [self get:U32(4) task:task];
        NSInteger base_vertex = tag == 29 ? (NSInteger)(int16_t)U16(14) : (NSInteger)U16(14);
        if (b) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexCount:U16(10) indexType:(MTLIndexType)U16(2) indexBuffer:b indexBufferOffset:U16(8)
                          instanceCount:U16(12) baseVertex:base_vertex baseInstance:U16(16)];
        draws++;
        break;
    }
    case 16: { /* {ref, primitive 16, 2 unused, offset 64} */
        id<MTLBuffer> b = [self get:U32(0) task:task];
        if (b) [e drawPrimitives:(MTLPrimitiveType)U16(4) indirectBuffer:b indirectBufferOffset:(NSUInteger)U64(8)];
        draws++;
        break;
    }
    case 17: { /* {primitive, index type, index ref, indirect ref, index offset 64, indirect offset 64} */
        id<MTLBuffer> index = [self get:U32(4) task:task], indirect = [self get:U32(8) task:task];
        if (index && indirect) [e drawIndexedPrimitives:(MTLPrimitiveType)U16(0) indexType:(MTLIndexType)U16(2) indexBuffer:index indexBufferOffset:(NSUInteger)U64(12)
                                          indirectBuffer:indirect indirectBufferOffset:(NSUInteger)U64(20)];
        draws++;
        break;
    }
    case 154: { /* {count, then a viewport and a render target offset for each view} */
        uint32_t count = U32(0);
        MTLVertexAmplificationViewMapping views[8];
        if (count == 0 || count > 8 || r.size < 4 + count * 8ull || ![e.device supportsVertexAmplificationCount:count]) break;
        for (uint32_t i = 0; i < count; i++) {
            views[i].viewportArrayIndexOffset = U32(4 + i * 8);
            views[i].renderTargetArrayIndexOffset = U32(8 + i * 8);
        }
        [e setVertexAmplificationCount:count viewMappings:views];
        break;
    }
    case 155: {
        MTLSize s;
        memcpy(&s, r.p, sizeof s);
        [e dispatchThreadsPerTile:s];
        break;
    }
    case 162: { /* threads per tile, then a tile region */
        MTLSize s;
        MTLRegion region;
        memcpy(&s, r.p, sizeof s);
        memcpy(&region, r.p + sizeof s, sizeof region);
        SEL sel = sel_registerName("dispatchThreadsPerTile:inRegion:");
        if ([(id)e respondsToSelector:sel]) ((void (*)(id, SEL, MTLSize, MTLRegion))objc_msgSend)(e, sel, s, region);
        else [e dispatchThreadsPerTile:s];
        break;
    }
    case 164: { /* where to write the tile size: {buffer ref, offset} */
        HvObject *o = [self object:U32(0) task:task];
        uint64_t off = U64(4);
        if (o && o->mapped && off + 4 <= o->length) {
            uint16_t dims[2] = {(uint16_t)e.tileWidth, (uint16_t)e.tileHeight};
            memcpy(o->mapped + off, dims, 4);
        }
        break;
    }
    default:
        [self complain:[NSString stringWithFormat:@"render command %u (%u bytes) skipped", tag, r.size]];
        break;
    }
}

/* Compute calls. Tags start at 200. */
- (void)compute:(id<MTLComputeCommandEncoder>)e tag:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    if (!pipeline_set && (tag == 200 || tag == 202)) return;
    switch (tag) {
    case 209: {
        MTLRegion region;
        if (r.size >= sizeof region) {
            memcpy(&region, r.p, sizeof region);
            [e setStageInRegion:region];
        }
        break;
    }
    case 214: /* barriers: encoders here are in order, and each exec is waited for */
    case 215:
        [e memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures];
        break;
    case 212: {
        id f = [self get:U32(0) task:task];
        if (f) [e updateFence:f];
        break;
    }
    case 213: {
        id f = [self get:U32(0) task:task];
        if (f) [e waitForFence:f];
        break;
    }
    case 208: {
        id state = [self get:U32(0) task:task];
        id resolved[]={state};
        if (state && binding_objects(&bindings,HV_BIND_PIPELINE,tag,r.p,r.size,resolved,1)) [e setComputePipelineState:state];
        pipeline_set = state != nil;
        if (tracing) fprintf(stderr, "trace:  pipeline %u %s\n", U32(0), [objc_getAssociatedObject(state, "hvname") UTF8String]);
        break;
    }
    case 203: {
        uint32_t index = U32(0), count = U32(4);
        if (count > 31) break;
        __unsafe_unretained id<MTLBuffer> buffers[31];
        id strong[31];
        NSUInteger offsets[31];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 12) task:task];
            buffers[i] = strong[i];
            offsets[i] = (NSUInteger)U64(12 + i * 12);
        }
        if (tracing) for (uint32_t i = 0; i < count; i++) {
            id<MTLBuffer> x = strong[i];
            fprintf(stderr, "trace:  cbuf %u ref %u off %lu len %lu:", index + i, U32(8 + i * 12), (unsigned long)offsets[i], (unsigned long)x.length);
            if (x && x.storageMode != MTLStorageModePrivate && offsets[i] < x.length)
                for (NSUInteger k = 0; k < 96 && offsets[i] + k + 4 <= x.length; k += 4)
                    fprintf(stderr, " %08x", *(uint32_t *)((uint8_t *)x.contents + offsets[i] + k));
            fprintf(stderr, "\n");
        }
        if(binding_objects(&bindings,HV_BIND_VERTEX_BUFFER,tag,r.p,r.size,strong,count)) [e setBuffers:buffers offsets:offsets withRange:NSMakeRange(index, count)];
        break;
    }
    case 207:
        if (tracing) fprintf(stderr, "trace:  cbuf %u offset now %llu\n", U32(0), (unsigned long long)U64(4));
        if(binding_objects(&bindings,HV_BIND_VERTEX_BUFFER,tag,r.p,r.size,NULL,0)) [e setBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)];
        break;
    case 206: {
        uint32_t index = U32(0), count = U32(4);
        if (count > 128) break;
        __unsafe_unretained id<MTLTexture> items[128];
        id strong[128];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if (tracing) for (uint32_t i = 0; i < count; i++) {
            id<MTLTexture> x = strong[i];
            HvObject *xo = [self object:U32(8 + i * 4) task:task];
            fprintf(stderr, "trace:  ctex %u ref %u %lux%lu fmt %lu type %u surface %s\n", index + i, U32(8 + i * 4), (unsigned long)x.width,
                    (unsigned long)x.height, (unsigned long)x.pixelFormat, xo ? xo->entry[0] & 0xff : 0, xo && xo->surface ? "yes" : "no");
        }
        if(binding_objects(&bindings,HV_BIND_VERTEX_TEXTURE,tag,r.p,r.size,strong,count)) [e setTextures:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 204: {
        uint32_t index = U32(0), count = U32(4);
        if (count > 16) break;
        __unsafe_unretained id<MTLSamplerState> items[16];
        id strong[16];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
        }
        if(binding_objects(&bindings,HV_BIND_VERTEX_SAMPLER,tag,r.p,r.size,strong,count)) [e setSamplerStates:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 211: [e setThreadgroupMemoryLength:(NSUInteger)U64(0) atIndex:U32(8)]; break;
    case 200: case 202: {
        MTLSize a, b;
        memcpy(&a, r.p, sizeof a), memcpy(&b, r.p + sizeof a, sizeof b);
        if (tracing) fprintf(stderr, "trace:  dispatch %u %lux%lux%lu by %lux%lux%lu\n", tag, (unsigned long)a.width, (unsigned long)a.height,
                             (unsigned long)a.depth, (unsigned long)b.width, (unsigned long)b.height, (unsigned long)b.depth);
        if (tag == 200) [e dispatchThreadgroups:a threadsPerThreadgroup:b];
        else [e dispatchThreads:a threadsPerThreadgroup:b];
        break;
    }
    case 216: /* {width, height} of the imageblock, 32x32 from macOS 27's glass and blur kernels: without it their
                 imageblock memory is undefined, and toolbars came out black with coloured blocks */
        if (r.size >= 8 && U32(0) && U32(4) && U32(0) <= 256 && U32(4) <= 256) [e setImageblockWidth:U32(0) height:U32(4)];
        break;
    case 219: /* not a command the framework knows either, though the guest sends it */
        break;
    default:
        [self complain:[NSString stringWithFormat:@"compute command %u (%u bytes) skipped", tag, r.size]];
        break;
    }
}

/* Blit calls. Tags start at 300. */
- (void)blit:(id<MTLBlitCommandEncoder>)e tag:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    switch (tag) {
    case 316: {
        id f = [self get:U32(0) task:task];
        if (f) [e updateFence:f];
        break;
    }
    case 317: {
        id f = [self get:U32(0) task:task];
        if (f) [e waitForFence:f];
        break;
    }
    case 300: { /* buffer to texture */
        id<MTLBuffer> b = [self get:U32(0) task:task];
        id<MTLTexture> t = [self get:U32(4) task:task];
        if (!b || !t) break;
        MTLSize size;
        MTLOrigin origin;
        memcpy(&size, r.p + 0x20, sizeof size), memcpy(&origin, r.p + 0x38, sizeof origin);
        [e copyFromBuffer:b sourceOffset:(NSUInteger)U64(8) sourceBytesPerRow:(NSUInteger)U64(0x10) sourceBytesPerImage:(NSUInteger)U64(0x18) sourceSize:size
                toTexture:t destinationSlice:U16(0x50) destinationLevel:U16(0x52) destinationOrigin:origin options:(MTLBlitOption)U32(0x54)];
        break;
    }
    case 301: { /* buffer to buffer */
        id<MTLBuffer> a = [self get:U32(0) task:task], b = [self get:U32(4) task:task];
        if (a && b) [e copyFromBuffer:a sourceOffset:(NSUInteger)U64(8) toBuffer:b destinationOffset:(NSUInteger)U64(0x10) size:(NSUInteger)U64(0x18)];
        break;
    }
    case 302: { /* texture to buffer */
        id<MTLTexture> t = [self get:U32(0) task:task];
        id<MTLBuffer> b = [self get:U32(4) task:task];
        if (!b || !t) break;
        MTLOrigin origin;
        MTLSize size;
        memcpy(&origin, r.p + 8, sizeof origin), memcpy(&size, r.p + 0x20, sizeof size);
        [e copyFromTexture:t sourceSlice:U16(0x50) sourceLevel:U16(0x52) sourceOrigin:origin sourceSize:size toBuffer:b
            destinationOffset:(NSUInteger)U64(0x38) destinationBytesPerRow:(NSUInteger)U64(0x40) destinationBytesPerImage:(NSUInteger)U64(0x48) options:(MTLBlitOption)U16(0x54)];
        break;
    }
    case 303: { /* texture to texture */
        id<MTLTexture> a = [self get:U32(0) task:task], b = [self get:U32(4) task:task];
        if (!a || !b) break;
        MTLOrigin from, to;
        MTLSize size;
        memcpy(&from, r.p + 8, sizeof from), memcpy(&size, r.p + 0x20, sizeof size), memcpy(&to, r.p + 0x38, sizeof to);
        [e copyFromTexture:a sourceSlice:U16(0x50) sourceLevel:U16(0x52) sourceOrigin:from sourceSize:size
                 toTexture:b destinationSlice:U16(0x54) destinationLevel:U16(0x56) destinationOrigin:to];
        break;
    }
    case 306: { /* fill: {ref, location, length, value} */
        id<MTLBuffer> b = [self get:U32(0) task:task];
        if (b) [e fillBuffer:b range:NSMakeRange((NSUInteger)U64(4), (NSUInteger)U64(12)) value:r.p[20]];
        break;
    }
    case 307: {
        id<MTLTexture> t = [self get:U32(0) task:task];
        if (t) [e generateMipmapsForTexture:t];
        break;
    }
    case 308: case 309: case 310: case 311: case 314: case 315: /* hints, and syncing memory Apple GPUs share */
        break;
    default:
        [self complain:[NSString stringWithFormat:@"blit command %u (%u bytes) skipped", tag, r.size]];
        break;
    }
}

/* What the guest asks about objects, answered in its own buffers: tags start at
   450, {ref, buffer ref, offset}. The guest's Metal puts these real host values
   into its argument buffers. */
- (void)info:(uint32_t)tag rec:(Rec)r task:(uint32_t)task {
    size_t required=tag==451?44:tag==469?52:tag==460?20:16;
    if(r.size<required){[self complain:@"truncated GPU info query"];return;}
    uint32_t ref = U32(0), bufref = U32(4);
    uint64_t off = U64(8);
    if (tag == 451 || tag == 469) { /* how big a texture would be in a heap: {description, buffer ref, offset} */
        uint32_t at = tag == 451 ? 0x20 : 0x28;
        if (r.size < at + 12) return;
        MTLTextureDescriptor *t = tag == 451 ? descriptor_v1(r.p) : descriptor_v2(r.p);
        HvObject *to = [self object:U32(at) task:task];
        refresh_pages(self, task, to);
        uint64_t where = U64(at + 4);
        if (!to || !to->mapped || where>to->length || 16>to->length-where) { [self complain:@"heap size query: no buffer"]; return; }
        MTLSizeAndAlign sa = [device heapTextureSizeAndAlignWithDescriptor:t];
        uint64_t v[2] = {sa.size, sa.align};
        memcpy(to->mapped + where, v, 16);
        return;
    }
    if (tag == 460) { /* an object's identifier: {ref, kind, buffer ref, offset} */
        bufref = U32(8);
        off = U64(12);
    }
    HvObject *to = [self object:bufref task:task];
    if (to) refresh_pages(self, task, to);
    uint8_t *out = to && to->mapped && off<=to->length && 28<=to->length-off ? to->mapped + off : NULL;
    id obj = [self get:ref task:task];
    if (!out || !obj) {
        [self complain:[NSString stringWithFormat:@"info %u: ref %u buffer %u (%s, %llu bytes) offset %llu: %s", tag, ref, bufref,
                        !to ? "unknown" : to->mapped ? "mapped" : "not mapped", to ? to->length : 0, off, out ? "no object" : "no buffer"]];
        return;
    }
    SEL index_sel = sel_registerName("resourceIndex");
    uint64_t index = [obj respondsToSelector:index_sel] ? ((uint64_t (*)(id, SEL))objc_msgSend)(obj, index_sel) : 0;
    switch (tag) {
    case 460: {
        SEL sel = sel_registerName("uniqueIdentifier");
        uint64_t v = [obj respondsToSelector:sel] ? ((uint64_t (*)(id, SEL))objc_msgSend)(obj, sel) : (uint64_t)(uintptr_t)obj;
        memcpy(out, &v, 8);
        break;
    }
    case 457: { /* render pipeline: {max threads, imageblock length, tile match, indirect} */
        id<MTLRenderPipelineState> p = obj;
        uint32_t v[2] = {(uint32_t)p.maxTotalThreadsPerThreadgroup, (uint32_t)p.imageblockSampleLength};
        memcpy(out, v, 8);
        out[8] = p.threadgroupSizeMatchesTileSize, out[9] = p.supportIndirectCommandBuffers;
        break;
    }
    case 450: { /* compute pipeline */
        id<MTLComputePipelineState> p = obj;
        uint64_t v[3] = {p.maxTotalThreadsPerThreadgroup, p.threadExecutionWidth, p.staticThreadgroupMemoryLength};
        memcpy(out, v, 24);
        out[24] = p.supportIndirectCommandBuffers;
        break;
    }
    case 463: { /* heap: where the whole of it is */
        id<MTLHeap> h = obj;
        HvObject *ho = [self object:ref task:task];
        uint64_t a = ho && ho->heap_whole ? ho->heap_whole.gpuAddress : 0;
        (void)h;
        memcpy(out, &a, 8);
        break;
    }
    case 461: { /* buffer */
        uint64_t a = [(id<MTLBuffer>)obj gpuAddress];
        memcpy(out, &a, 8);
        break;
    }
    case 462: case 464: case 466: case 467: case 468: { /* texture, sampler, render, compute, depth-stencil */
        MTLResourceID id_ = ((MTLResourceID (*)(id, SEL))objc_msgSend)(obj, @selector(gpuResourceID));
        memcpy(out, &id_, 8);
        memcpy(out + 8, &index, 8);
        break;
    }
    default:
        [self complain:[NSString stringWithFormat:@"info command %u (%u bytes) skipped", tag, r.size]];
        break;
    }
}

/* One exec: {task, resources, buffers}, {ref, flags} per resource, {offset, length} per buffer. */
/* Commits without waiting: the next batch can be encoded while the GPU does this one. */
- (void)commit:(id<MTLCommandBuffer>)cb channel:(uint32_t)ch stamp:(uint32_t)stamp complete:(BOOL)complete {
    static int sync = -1; /* HV_PVG_SYNC: wait for the GPU after every batch */
    if (sync < 0) sync = getenv("HV_PVG_SYNC") != NULL;
    HvPvgLite *l = lite;
    int pending=atomic_fetch_add(&inflight, 1)+1;
    BOOL timed=gpu_timing||atomic_load_explicit(&capture_timing,memory_order_relaxed);
    /* Metal GPU timestamps use the CACurrentMediaTime clock domain. Never
       subtract a CLOCK_MONOTONIC timestamp from them. All work stays opt-in. */
    double queuedAt=timed?CACurrentMediaTime():0;
    if(timed){uint64_t peak=atomic_load(&gpu_inflight_peak);while((uint64_t)pending>peak&&!atomic_compare_exchange_weak(&gpu_inflight_peak,&peak,(uint64_t)pending)){}}
    dispatch_group_enter(completions);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.error) {
            self->failed++;
            fprintf(stderr, "hengevm: pvg-metal: command buffer: %s\n", done.error.localizedDescription.UTF8String);
        }
        if (self->gpu_timing || atomic_load_explicit(&self->capture_timing,memory_order_relaxed)) {
        double elapsed = done.GPUEndTime - done.GPUStartTime;
        atomic_fetch_add_explicit(&self->gpu_completed, 1, memory_order_relaxed);
        if (done.GPUStartTime > 0 && isfinite(elapsed) && elapsed >= 0 && elapsed < 3600) {
            uint64_t ns = (uint64_t)(elapsed * 1e9);
            atomic_fetch_add_explicit(&self->gpu_duration_ns, ns, memory_order_relaxed);
            uint64_t maximum = atomic_load_explicit(&self->gpu_max_ns, memory_order_relaxed);
            while (ns > maximum && !atomic_compare_exchange_weak_explicit(&self->gpu_max_ns, &maximum, ns, memory_order_relaxed, memory_order_relaxed)) {}
            double queueDelay=done.GPUStartTime-queuedAt,completionDelay=CACurrentMediaTime()-queuedAt;
            if(queuedAt>0&&isfinite(queueDelay)&&isfinite(completionDelay)&&queueDelay>=0&&completionDelay>=queueDelay&&completionDelay<300) {
                uint64_t q=(uint64_t)(queueDelay*1e9);atomic_fetch_add(&self->gpu_queue_samples,1);
                atomic_fetch_add(&self->gpu_queue_ns,q);atomic_fetch_add(&self->gpu_completion_ns,(uint64_t)(completionDelay*1e9));
                uint64_t peak=atomic_load(&self->gpu_queue_max_ns);while(q>peak&&!atomic_compare_exchange_weak(&self->gpu_queue_max_ns,&peak,q)){}
            }
        } else atomic_fetch_add_explicit(&self->gpu_timing_missing, 1, memory_order_relaxed);
        }
        if (complete) hv_pvg_lite_complete(l, ch, stamp);
        atomic_fetch_sub(&self->inflight, 1);
        dispatch_group_leave(self->completions);
    }];
    os_unfair_lock_lock(&submission_lock);[cb commit];os_unfair_lock_unlock(&submission_lock);
    last_cb = cb;
    if (sync) [cb waitUntilCompleted];
}

/* A command that used the GPU not at all, or waited for by others: its stamp after everything before it. */
- (void)finishChannel:(uint32_t)ch stamp:(uint32_t)stamp {
    if (atomic_load(&inflight) == 0) {
        hv_pvg_lite_complete(lite, ch, stamp);
        return;
    }
    [self commit:[queue commandBuffer] channel:ch stamp:stamp complete:YES];
}

/* Returns YES if the GPU's completion gives the stamp back. */
- (BOOL)encodeCommandCount:(NSUInteger)count fetch:(NSData *(^)(NSUInteger))fetch task:(uint32_t)task commandBuffer:(id)cb metal4Job:(BOOL)metal4Job {
    id e = nil; /* the open encoder */
    uint32_t etype = 0;
    for (NSUInteger commandIndex=0;commandIndex<count;commandIndex++) { @autoreleasepool {
        NSData *copy=fetch(commandIndex);if(!copy)continue;
        HvGpuSegment segment;HvGpuReject malformed={0};
        if(!hv_gpu_segment(copy.bytes,copy.length,&segment,&malformed)) {
            if(metal4Job)return NO;
            [self complain:@"truncated GPU segment header"];continue;
        }
        uint32_t type=segment.type,cont=segment.continuation,more=segment.more;
        size_t at=segment.start;HvGpuRecord record;int recordStatus;
        if (!cont && e) { [e endEncoding]; e = nil; }
        if (type > 2) {
            while((recordStatus=hv_gpu_next(&segment,&at,&record,&malformed))>0) {
                Rec r={record.bytes,(uint32_t)record.size};
                if (type == 4) [self info:record.tag rec:r task:task];
                else [self complain:[NSString stringWithFormat:@"encoder type %u command %u (%zu bytes) skipped",type,record.tag,record.size]];
            }
            if(recordStatus<0&&metal4Job)return NO;
            continue;
        }
        if (!e && type == 1) { e = [cb computeCommandEncoder]; pipeline_set = NO; hv_binding_reset(&bindings); if(metal4Job&&!e)return NO; }
        if (!e && type == 2) { e = [cb blitCommandEncoder]; if(metal4Job&&!e)return NO; }
        etype = type;
        @try {
            while((recordStatus=hv_gpu_next(&segment,&at,&record,&malformed))>0) {
                uint32_t tag=record.tag,size=(uint32_t)record.size+8;
                Rec r={record.bytes,(uint32_t)record.size};
                if (etype == 0 && tag >= 30 && tag <= 36) { /* these describe the pass that follows */
                    if (tag == 30 && size >= 12) pre_raster_samples = U32(0);
                    else if (tag == 34 && size >= 12) pre_imageblock = U32(0);
                    else if (tag == 35 && size >= 12) pre_threadgroup = U32(0);
                    else if (tag == 36 && size >= 12) pre_tile_w = U32(0) & 0xffff, pre_tile_h = U32(0) >> 16;
                    else if (tag == 33 || tag == 32) [self complain:[NSString stringWithFormat:@"pass description %u (%u bytes) not done", tag, size]];
                } else if (etype == 0 && tag == 26) {
                    if (e) { [e endEncoding];e=nil; }
                    e = [self beginPass:r task:task commandBuffer:cb];
                    pipeline_set = NO, tess_factors = NO; hv_binding_reset(&bindings);
                    if(metal4Job&&!e)return NO;
                } else if (e) {
                    if (etype == 0) [self render:e tag:tag rec:r task:task];
                    else if (etype == 1) [self compute:e tag:tag rec:r task:task];
                    else [self blit:e tag:tag rec:r task:task];
                }
            }
            if(recordStatus<0&&metal4Job){if(@available(macOS 26.0,iOS 26.0,*))[(HvMetal4Encoder *)e abortEncoding];return NO;}
        } @catch (NSException *x) {
            if(metal4Job){
                if(@available(macOS 26.0,iOS 26.0,*))[(HvMetal4Encoder *)e abortEncoding];
                /* The enclosing submission owns discard/replay and bounded
                   rejection reporting. Preserve the actual pipeline/encoder
                   reason instead of reducing every failure to a silent NO. */
                @throw;
            }
            [self complain:[NSString stringWithFormat:@"exception: %@", x.reason]];
            failed++;
        }
        if (!more && e) { [e endEncoding]; e = nil; }
    }
    }
    if (e) [e endEncoding];
    return YES;
}
- (BOOL)encodeCommands:(NSArray<NSData *> *)commands task:(uint32_t)task commandBuffer:(id)cb metal4Job:(BOOL)metal4Job {
    return [self encodeCommandCount:commands.count fetch:^NSData *(NSUInteger i){return commands[i];} task:task commandBuffer:cb metal4Job:metal4Job];
}

- (BOOL)exec:(const uint32_t *)a length:(uint32_t)len channel:(uint32_t)ch stamp:(uint32_t)stamp {
    uint32_t task = a[0], nres = a[1], nbuf = a[2];
    if (12 + nres * 8ull + nbuf * 16ull > len) { /* never quietly: a lost job is a frame that never gets drawn */
        [self complain:[NSString stringWithFormat:@"exec of %u bytes dropped: task %u, %u resources, %u buffers", len, task, nres, nbuf]];
        return NO;
    }
    const uint32_t *res = a + 3;
    const uint8_t *bufs = (const uint8_t *)(res + nres * 2);
    static const char *trace_file;
    static BOOL trace_checked;
    if (!trace_checked) trace_checked = YES, trace_file = getenv("HV_PVG_TRACE_FILE");
    double t_begin = now_seconds();
    tracing = hv_trace_file_enabled(&trace_gate, trace_file, t_begin);
    if (tracing) fprintf(stderr, "trace: exec task %u, %u resources, %u buffers\n", task, nres, nbuf);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = nil;
    BOOL sync_after = NO;
    for (uint32_t i = 0; i < nres; i++) {
        HvObject *o = [self object:res[i * 2] task:task];
        if (!o) continue;
        if (o->mapped) refresh_pages(self, task, o);
        if (o->surface) sync_surface_once(self, o->surface, execs + 1);
        if (resource_tally && (o->entry[0] & 0xff) == OBJ_MAPPED_TEXTURE) {
            static uint32_t seen[256];
            uint32_t f = res[i * 2 + 1] & 0xff, key = res[i * 2] & 0xff;
            if (seen[key] != f + 1) {
                seen[key] = f + 1;
                fprintf(stderr, "pvgres task %u ref %u mapped flags %x\n", task, res[i * 2], res[i * 2 + 1]);
            }
        }
        if (res[i * 2 + 1] & 1) o->guest_stale = NO, o->host_valid = NO; /* the guest wrote it */
        if (o->guest_backed && !o->host_valid) {
            if (!o->guest_stale && [self page:o toGuest:NO task:task blit:&blit commandBuffer:cb]) o->host_valid = YES;
        }
        if (res[i * 2 + 1] & 4) sync_after = YES;
    }
    [blit endEncoding];
    /* Bit 1: this exec writes it, so the guest's copy is out of date from here on. Never
       upload that over what the GPU drew: mostly zeros, which show as black boxes. */
    for (uint32_t i = 0; i < nres; i++)
        if (res[i * 2 + 1] & 2) { /* and what it is made from: a texture in a heap is the heap's bytes */
            for (HvObject *o = [self object:res[i * 2] task:task]; o; o = o->parent) o->guest_stale = YES;
        }
    uint64_t commandBytes=0;
    for(uint32_t b=0;b<nbuf;b++){uint64_t n;memcpy(&n,bufs+b*16+8,8);if(n>=8 && n<=(64u<<20))commandBytes+=n;}
    BOOL snapshotCommands=commandBytes<=(64u<<20);
    NSMutableArray<NSData *> *commands=[NSMutableArray new];
    for(uint32_t b=0;snapshotCommands && b<nbuf;b++){
        uint64_t off,blen;memcpy(&off,bufs+b*16,8);memcpy(&blen,bufs+b*16+8,8);
        if(blen>(64u<<20)||blen<8)continue;
        NSMutableData *copy=[NSMutableData dataWithLength:(NSUInteger)blen];
        if(hv_pvg_lite_task_read(lite,task,off,copy.mutableBytes,(uint32_t)blen)){[self complain:@"command buffer unreadable"];continue;}
        [commands addObject:copy];
    }
    BOOL hasMetal4=NO;
    if(@available(macOS 26.0,iOS 26.0,*))hasMetal4=metal4!=nil;
    NSArray<HvMetal4Run *> *runs=snapshotCommands&&hasMetal4?hv_metal4_command_runs(commands):@[];
    for(HvMetal4Run *run in runs) {
    BOOL used4=NO,metadataOnly=NO;
    if(@available(macOS 26.0,iOS 26.0,*)){
    HvGpuReject rejection=run->rejection;
    HvMetal4Plan *plan=metal4?run->plan:nil;
    BOOL supported4=plan&&plan.graphics;
    if(plan&&!plan.graphics){metal4_metadata++;metadataOnly=YES;}
    if(metal4&&!plan) {
        metal4_unsupported++;
        if(!rejection.reason)rejection.reason=HV_GPU_EMPTY;
        metal4_last_reject=rejection;
        hv_gpu_reject_note(&metal4_reject_stats,rejection);
        uint64_t seen=++metal4_reject_reasons[rejection.reason];
        if(seen<=3)fprintf(stderr,"hengevm: metal4-stream-rejected: reason=%u type=%u tag=%u offset=%zu needed=%zu available=%zu task=%u (original GPU submission retained)\n",rejection.reason,rejection.type,rejection.tag,rejection.offset,rejection.needed,rejection.available,task);
    }
    if(supported4){
        HvMetal4Job *job=[metal4 begin];
        if(job){
            for(uint32_t i=0;i<nres;i++)[metal4 retainResource:[self get:res[i*2] task:task] job:job];
            HvMetal4Buffer *bridge=[HvMetal4Buffer new];bridge->runtime=metal4;bridge->job=job;
            bridge->passOptions=plan.options;
            uint64_t oldDraws=draws;
            uint32_t oldSamples=pre_raster_samples,oldImage=pre_imageblock,oldMemory=pre_threadgroup,oldW=pre_tile_w,oldH=pre_tile_h;
            BOOL warming=NO;
            @try { used4=[self encodeCommands:run->commands task:task commandBuffer:bridge metal4Job:YES]; }
            @catch(NSException *exception){
                warming=[exception.name isEqualToString:@"HengeMetal4Warming"];
                if(!warming&&metal4_encoder_rejected<3)fprintf(stderr,"hengevm: metal4-fallback: task=%u reason=%s (complete original command stream retained)\n",task,exception.reason.UTF8String?:"encoder unavailable");
                used4=NO;
            }
            if(!used4){if(warming)metal4_warming++;else metal4_encoder_rejected++;}
            if(used4){
                [self commit:cb channel:0 stamp:0 complete:NO];
                dispatch_group_enter(completions);atomic_fetch_add(&inflight,1);
                BOOL queued=[metal4 commit:job classicQueue:queue lock:&submission_lock drawable:nil completion:^(BOOL ok){
                    atomic_fetch_add(&self->metal4_guest_completed,1);
                    if(!ok){atomic_fetch_add(&self->failed,1);atomic_fetch_add(&self->metal4_guest_failed,1);}
                    atomic_fetch_sub(&self->inflight,1);dispatch_group_leave(self->completions);
                }];
                cb=[queue commandBuffer];
                if(queued){
                    if(!metal4_replayed)fprintf(stderr,"hengevm: metal4-first-guest: task=%u draws=%llu; native host GPU render/compute replay active\n",task,(unsigned long long)(draws-oldDraws));
                    metal4_replayed++;
                }
                else{
                    metal4_bridge_rejected++;used4=NO;atomic_fetch_sub(&inflight,1);dispatch_group_leave(completions);draws=oldDraws;
                    pre_raster_samples=oldSamples;pre_imageblock=oldImage;pre_threadgroup=oldMemory;pre_tile_w=oldW;pre_tile_h=oldH;
                }
            }else{
                [metal4 discard:job];draws=oldDraws;
                pre_raster_samples=oldSamples;pre_imageblock=oldImage;pre_threadgroup=oldMemory;pre_tile_w=oldW;pre_tile_h=oldH;
            }
        }else metal4_job_missed++;
    }
    }
    if(!used4){
        if(!metadataOnly)metal4_fallback++;
        [self encodeCommands:run->commands task:task commandBuffer:cb metal4Job:NO];
    }
    }
    if(snapshotCommands&&!hasMetal4) {
        metal4_fallback++;
        [self encodeCommands:commands task:task commandBuffer:cb metal4Job:NO];
    }
    if(!snapshotCommands) {
        metal4_fallback++;
        [self encodeCommandCount:nbuf fetch:^NSData *(NSUInteger b){
            uint64_t off,n;memcpy(&off,bufs+b*16,8);memcpy(&n,bufs+b*16+8,8);
            if(n<8||n>(64u<<20))return nil;
            NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)n];
            if(hv_pvg_lite_task_read(self->lite,task,off,data.mutableBytes,(uint32_t)n)){[self complain:@"command buffer unreadable"];return nil;}
            return data;
        } task:task commandBuffer:cb metal4Job:NO];
    }
    if (sync_after) { /* the guest wants these back as soon as this is done */
        id<MTLBlitCommandEncoder> back = nil;
        for (uint32_t i = 0; i < nres; i++) {
            if (!(res[i * 2 + 1] & 4)) continue;
            HvObject *o = [self object:res[i * 2] task:task];
            if (!o || !o->guest_backed) continue;
            if ([self page:o toGuest:YES task:task blit:&back commandBuffer:cb]) o->guest_stale = NO;
        }
        [back endEncoding];
    }
    double t1 = now_seconds();
    [self commit:cb channel:ch stamp:stamp complete:YES];
    double t2 = now_seconds();
    encode_time += t1 - t_begin, gpu_wait_time += t2 - t1;
    BOOL capture = atomic_load_explicit(&capture_timing, memory_order_relaxed);
    BOOL capture_report = capture && t2 >= capture_log_next;
    if (!capture) capture_log_next = 0;
    if ((++execs % 2000 == 0 && (diagnostics_enabled || gpu_timing || tracing)) || capture_report) {
        if (capture_report) capture_log_next = t2 + 5;
        static double t0;
        if (!t0) t0 = now_seconds();
        fprintf(stderr, "hengevm: pvg-metal: %llu execs, %llu draws, %llu failed, %llu synced, %llu remaps, %.0f s; encoding %.2f s, commit/wait CPU time %.2f s\n", (unsigned long long)execs, (unsigned long long)draws, (unsigned long long)failed, (unsigned long long)synced, (unsigned long long)remaps, now_seconds() - t0, encode_time, gpu_wait_time);
        encode_time = gpu_wait_time = 0;
        fprintf(stderr, "hengevm: gpu-execution: enabled=%d completed=%llu duration_ms=%.2f max_ms=%.2f unavailable=%llu (classic command buffers only; Metal4 timing is separate; overlapping durations are not utilization)\n",
                gpu_timing || capture, (unsigned long long)atomic_load_explicit(&gpu_completed, memory_order_relaxed),
                atomic_load_explicit(&gpu_duration_ns, memory_order_relaxed) / 1e6,
                atomic_load_explicit(&gpu_max_ns, memory_order_relaxed) / 1e6,
                (unsigned long long)atomic_load_explicit(&gpu_timing_missing, memory_order_relaxed));
        fprintf(stderr, "hengevm: gpu-trace-gate: probes=%llu cached_checks=%llu interval=1s (cumulative)\n",
                (unsigned long long)trace_gate.probes, (unsigned long long)trace_gate.cached);
        fprintf(stderr,"hengevm: gpu-queue-latency: samples=%llu commit_to_start_ms=%.2f max_ms=%.2f commit_to_callback_ms=%.2f inflight_peak=%llu (cumulative overlapping lifetimes, not GPU utilization; timestamps share the Metal clock)\n",(unsigned long long)atomic_load(&gpu_queue_samples),atomic_load(&gpu_queue_ns)/1e6,atomic_load(&gpu_queue_max_ns)/1e6,atomic_load(&gpu_completion_ns)/1e6,(unsigned long long)atomic_load(&gpu_inflight_peak));
        if(@available(macOS 26.0,iOS 26.0,*)){HvMetal4Runtime *m4=metal4;
        fprintf(stderr,"hengevm: metal4-replay: submitted=%llu fallback=%llu guest_completed=%llu guest_errors=%llu all_gpu_completed=%llu metadata_only=%llu unavailable=%llu (display completion is separate from guest execution)\n",(unsigned long long)metal4_replayed,(unsigned long long)metal4_fallback,(unsigned long long)atomic_load(&metal4_guest_completed),(unsigned long long)atomic_load(&metal4_guest_failed),metal4?(unsigned long long)atomic_load(&m4->completed):0,(unsigned long long)metal4_metadata,metal4?(unsigned long long)atomic_load(&m4->unavailable):0);
        if(metal4)fprintf(stderr,"hengevm: metal4-rejection-detail: header=%llu record=%llu encoder=%llu tag=%llu payload=%llu empty=%llu last_reason=%u type=%u tag_id=%u offset=%zu bytes=%zu (bounded counters, no shader/resource contents)\n",(unsigned long long)metal4_reject_reasons[HV_GPU_HEADER],(unsigned long long)metal4_reject_reasons[HV_GPU_RECORD],(unsigned long long)metal4_reject_reasons[HV_GPU_ENCODER],(unsigned long long)metal4_reject_reasons[HV_GPU_TAG],(unsigned long long)metal4_reject_reasons[HV_GPU_PAYLOAD],(unsigned long long)metal4_reject_reasons[HV_GPU_EMPTY],metal4_last_reject.reason,metal4_last_reject.type,metal4_last_reject.tag,metal4_last_reject.offset,metal4_last_reject.available);
        if(metal4)fprintf(stderr,"hengevm: metal4-fallback-counts: unsupported_stream=%llu encoder_pipeline=%llu pool_or_disabled=%llu bridge_allocation=%llu pipeline_warming=%llu (encoder-run compatibility; unrelated supported work stays on Metal4)\n",(unsigned long long)metal4_unsupported,(unsigned long long)metal4_encoder_rejected,(unsigned long long)metal4_job_missed,(unsigned long long)metal4_bridge_rejected,(unsigned long long)metal4_warming);
        if(metal4)for(unsigned rank=0;rank<3;rank++) {
            const HvGpuRejectBucket *b=hv_gpu_reject_top(&metal4_reject_stats,rank);if(!b)break;
            fprintf(stderr,"hengevm: metal4-rejection-hotspot: rank=%u count=%llu reason=%u type=%u tag=%u min_bytes=%zu max_bytes=%zu unclassified=%llu (cumulative rejected runs; classic GPU replay retained, not lost draws)\n",rank+1,(unsigned long long)b->count,b->reason,b->type,b->tag,b->min_bytes,b->max_bytes,(unsigned long long)metal4_reject_stats.overflow);
        }
        if(metal4)fprintf(stderr,"hengevm: metal4-runtime: GPU_ms=%.2f max_ms=%.2f pipeline_hits=%llu pipeline_compiles=%llu archive_writes=%llu presentation_backpressure=%llu (GPU replay and display combined; CPU emulation stays on CPU)\n",atomic_load(&m4->gpu_duration_ns)/1e6,atomic_load(&m4->gpu_max_ns)/1e6,(unsigned long long)atomic_load(&m4->pipeline_cache_hits),(unsigned long long)atomic_load(&m4->pipeline_cache_misses),(unsigned long long)atomic_load(&m4->pipeline_cache_writes),(unsigned long long)atomic_load(&presentation_backpressure));
        if(metal4)fprintf(stderr,"hengevm: metal4-pipeline-timing: compile_attempts=%llu compile_ms=%.2f max_ms=%.2f (host elapsed time inside compiler calls; excludes archive lookup and GPU execution; no draw-time sampling)\n",(unsigned long long)atomic_load(&m4->pipeline_cache_misses),atomic_load(&m4->pipeline_compile_ns)/1e6,atomic_load(&m4->pipeline_compile_max_ns)/1e6);
        if(metal4)fprintf(stderr,"hengevm: metal4-pipeline-warmup: admitted=%llu completed=%llu deferred=%llu cancelled=%llu classic_while_warming=%llu (bounded utility worker; frames retain original pipelines; no FPS claim)\n",(unsigned long long)atomic_load(&m4->pipelineQueue->admitted),(unsigned long long)atomic_load(&m4->pipelineQueue->completed),(unsigned long long)atomic_load(&m4->pipelineQueue->deferred),(unsigned long long)atomic_load(&m4->pipelineQueue->cancelled),(unsigned long long)metal4_warming);
        }
        fprintf(stderr,"hengevm: gpu-binding-cache: enabled=%d attempts=%llu skipped=%llu (exact resolved objects; per-encoder state; no guest commands dropped)\n",!bindings.disabled,(unsigned long long)bindings.attempts,(unsigned long long)bindings.skipped);
        fprintf(stderr, "hengevm: gpu-batch-cache: enabled=%d object_hits=%llu object_reads=%llu page_hits=%llu page_checks=%llu (immutable objects and exact task/command epochs)\n",
            batch_cache,(unsigned long long)object_hits,(unsigned long long)object_reads,(unsigned long long)page_hits,(unsigned long long)page_checks);
        fprintf(stderr, "hengevm: gpu-planar-registry: created=%llu reused_without_allocation=%llu identity=all-pages-and-layout (cumulative)\n",
            (unsigned long long)planar_creations,(unsigned long long)planar_reuses);
        fprintf(stderr, "hengevm: gpu-surface-checks: performed=%llu duplicate_scans_avoided=%llu (exact surface identity; one check per command batch)\n",
                (unsigned long long)surface_checks, (unsigned long long)surface_checks_avoided);
        fprintf(stderr, "hengevm: gpu-libraries: hits=%llu loads=%llu retained=%lu bytes=%lu load_ms=%.2f worst_ms=%.2f (exact bytes; session-only; limits %lu libraries/%.1fMiB binary keys)\n",
                (unsigned long long)library_cache.hits, (unsigned long long)library_cache.loads,
                (unsigned long)library_cache.count, (unsigned long)library_cache.retainedBytes,
                library_load_seconds * 1000, library_load_worst * 1000,
                (unsigned long)library_cache.admissionEntries, library_cache.admissionBytes/1048576.0);
        fprintf(stderr, "hengevm: gpu-pipelines: builds=%llu total_ms=%.2f worst_ms=%.2f (cumulative host pipeline creation, including failures)\n",
                (unsigned long long)pipeline_builds, pipeline_seconds * 1000, pipeline_worst_seconds * 1000);
        fprintf(stderr, "hengevm: gpu-pipeline-archives: hits=%llu compiled=%llu pending=%lu bypass=%llu hit_ms=%.2f compile_ms=%.2f pressure_suspended=%d (session totals; disk cache survives launches, save scheduled 8s from first pending PSO)\n",
                (unsigned long long)pipes_hit,(unsigned long long)pipes_compiled,(unsigned long)archive_pending.count,
                (unsigned long long)pipes_unsaveable,hit_ms,compile_ms,archive_pressure_suspended);
        fprintf(stderr, "hengevm: gpu-function-reuse: hits=%llu builds=%llu memory_warnings=%llu (exact binary, unspecialized first function; worker-owned LRU)\n",
                (unsigned long long)library_cache.functionHits, (unsigned long long)library_cache.functionBuilds,
                (unsigned long long)cache_warnings);
        /* Constant-time ownership clues alongside the existing report. Includes
           in-flight allocations; neither a process footprint nor proof of a leak. */
        fprintf(stderr, "hengevm: gpu-memory: device_allocated=%.1fMiB tasks=%lu surfaces=%lu mapped_textures=%lu planar=%lu (Metal device allocations including in-flight work; not process footprint)\n",
                (double)device.currentAllocatedSize / (1 << 20), (unsigned long)tasks.count,
                (unsigned long)surfaces.count, (unsigned long)mapped_textures.count, (unsigned long)planar.count);
        os_unfair_lock_lock(&screen_lock);
        uint64_t suppressed = cursor_damage.suppressed, coalesced = frame_pacing.coalesced;
        os_unfair_lock_unlock(&screen_lock);
        fprintf(stderr, "hengevm: presentation-work: unchanged_cursor_suppressed=%llu frames_coalesced=%llu (exact cursor state; guest swaps remain authoritative)\n",
                (unsigned long long)suppressed, (unsigned long long)coalesced);
    }
    return YES;
}

/* Every possible half-float value to a display byte, as the screen would show it in the current mode (see hv_half_mode). */
static const uint8_t *half_to_byte(void) {
    static uint8_t *tables[2];
    int mode = hv_half_mode_get();
    if (tables[mode]) return tables[mode];
    uint8_t *t = malloc(65536);
    for (uint32_t i = 0; i < 65536; i++) {
        uint16_t bits = (uint16_t)i;
        __fp16 h;
        memcpy(&h, &bits, 2);
        float v = h;
        t[i] = !(v > 0) ? 0 : v >= 1 ? 255 : (uint8_t)(hv_half_shown(v, mode) * 255.0f + 0.5f);
    }
    tables[mode] = t;
    return t;
}

/* Op 4: a new pointer image in the kernel task's memory, premultiplied BGRA:
   {port, 0, offset, mapped length, stride, width, height, hot x, hot y, sum}. */
- (void)cursorGlyph:(const uint32_t *)a length:(uint32_t)n {
    if (n < 0x2c || a[0] >= HV_PVG_DISPLAY_PORTS) return;
    uint64_t off, stride;
    memcpy(&off, a + 2, 8), memcpy(&stride, a + 6, 8);
    uint16_t w, h, hx, hy;
    memcpy(&w, (const uint8_t *)a + 0x20, 2), memcpy(&h, (const uint8_t *)a + 0x22, 2);
    memcpy(&hx, (const uint8_t *)a + 0x24, 2), memcpy(&hy, (const uint8_t *)a + 0x26, 2);
    if (!w || !h || w > 512 || h > 512 || stride < (uint64_t)w * 4 || stride > 8192) return;
    uint8_t *bits = malloc((size_t)stride * h);
    if (!bits) { [self complain:@"pointer image allocation failed"]; return; }
    if (hv_pvg_lite_task_read(lite, 0, off, bits, (uint32_t)stride * h)) {
        free(bits);
        [self complain:@"pointer image unreadable"];
        return;
    }
    /* Repeated glyph notifications need no new texture/upload/revision. The
       guest bytes are read first; identity alone cannot prove unchanged pixels.
       Position/visibility changes still flow through the normal cursor path. */
    if (a[0] == 0) {
        os_unfair_lock_lock(&screen_lock);
        BOOL identical = cursor && cursor_tex && cursor_w == w && cursor_h == h &&
            cursor_stride == stride && cursor_hot_x == hx && cursor_hot_y == hy &&
            !memcmp(cursor, bits, (size_t)stride * h);
        os_unfair_lock_unlock(&screen_lock);
        if (identical) { free(bits); [self drawCursor]; return; }
    }
    MTLTextureDescriptor *ct = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    ct.storageMode = MTLStorageModeShared;
    id<MTLTexture> glyph = [device newTextureWithDescriptor:ct];
    if (!glyph) { free(bits); [self complain:@"pointer texture allocation failed"]; return; }
    [glyph replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bits bytesPerRow:(NSUInteger)stride];
    if (a[0] == 1) {
        link_cursor=glyph;link_cw=w;link_ch=h;link_hx=hx;link_hy=hy;
        free(bits);[self sendLinkMapping:link_mapping];return;
    }
    free(cursor);
    os_unfair_lock_lock(&screen_lock);
    cursor = bits, cursor_w = w, cursor_h = h, cursor_stride = (uint32_t)stride, cursor_hot_x = hx, cursor_hot_y = hy;
    cursor_tex = glyph;
    cursor_revision++;
    os_unfair_lock_unlock(&screen_lock);
    if (getenv("HV_PVG_CURSOR_LOG")) fprintf(stderr, "pvgcursor glyph %ux%u hot %d,%d stride %u first alpha %u\n", w, h, hx, hy, (uint32_t)stride, bits[(size_t)(h / 2) * stride + (size_t)(w / 2) * 4 + 3]);
    [self drawCursor];
}

- (BOOL)usesNativePresentation {
    os_unfair_lock_lock(&screen_lock);
    BOOL attached = native_output_selected || layer != nil;
    os_unfair_lock_unlock(&screen_lock);
    return attached;
}

/* Puts back what the pointer covered, and draws it where the shared page says it is now. */
- (void)drawCursor {
    if ([self usesNativePresentation]) {
        [self screenChanged];
        return;
    }
    if (!frame || !base) return;
    uint32_t w = frame_w, h = frame_h;
    for (int y = drawn_y; y < drawn_y + drawn_h; y++) memcpy(frame + (size_t)y * w * 4 + (size_t)drawn_x * 4, base + (size_t)y * w * 4 + (size_t)drawn_x * 4, (size_t)drawn_w * 4);
    drawn_w = drawn_h = 0;
    const uint8_t *page = hv_pvg_lite_display_page(lite);
    if (!page || !cursor || !(cursor_shown || page[0xe04])) return;
    uint32_t where = __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE);
    if (getenv("HV_PVG_CURSOR_LOG")) {
        static uint32_t last;
        if (where != last) fprintf(stderr, "pvgcursor at %u,%u shown %d flag %d\n", where & 0xffff, where >> 16, cursor_shown, page[0xe04]);
        last = where;
    }
    if (where == 0xffffffff) return;
    /* Bigger than the guest draws it. The hot spot stays where it points. */
    const int scale = cursor_scale(page,w);
    /* The pointer's place is in the display mode's pixels; a scaled resolution's frame is smaller than the mode. */
    uint32_t mw = w, mh = h;
    hv_pvg_lite_mode(&mw, &mh);
    if (!mw || !mh) mw = w, mh = h;
    int x = (int)((uint64_t)(where & 0xffff) * w / mw) - cursor_hot_x * scale, y = (int)((uint64_t)(where >> 16) * h / mh) - cursor_hot_y * scale;
    int cw = (int)cursor_w * scale, ch = (int)cursor_h * scale;
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + cw > (int)w ? (int)w : x + cw, y1 = y + ch > (int)h ? (int)h : y + ch;
    if (x1 <= x0 || y1 <= y0) return;
    for (int py = y0; py < y1; py++) {
        const uint8_t *row = cursor + (size_t)((py - y) / scale) * cursor_stride;
        uint8_t *dst = frame + (size_t)py * w * 4 + (size_t)x0 * 4;
        for (int px = x0; px < x1; px++, dst += 4) {
            const uint8_t *src = row + (size_t)((px - x) / scale) * 4;
            uint32_t keep = 255u - src[3];
            dst[0] = (uint8_t)(src[0] + (dst[0] * keep + 127) / 255);
            dst[1] = (uint8_t)(src[1] + (dst[1] * keep + 127) / 255);
            dst[2] = (uint8_t)(src[2] + (dst[2] * keep + 127) / 255);
        }
    }
    drawn_x = x0, drawn_y = y0, drawn_w = x1 - x0, drawn_h = y1 - y0;
}

#include "pvg_screen.h"

- (BOOL)prepareScreenForLayer:(CAMetalLayer *)target {
    if (!screen_pipe || !linear_pipe || !cursor_pipe) {
        NSError *err = nil;
        double started = now_seconds();
        id<MTLLibrary> lib = [device newDefaultLibrary];
        BOOL bundled = lib && [lib newFunctionWithName:@"screen_v"]
            && [lib newFunctionWithName:@"screen_plain"]
            && [lib newFunctionWithName:@"screen_linear"]
            && [lib newFunctionWithName:@"screen_cursor"];
        if (!bundled) lib = [device newLibraryWithSource:screen_shaders options:nil error:&err];
        if (!lib) { [self complain:[NSString stringWithFormat:@"screen shaders: %@", err.localizedDescription]]; return NO; }
        if(metal4){if(@available(macOS 26.0,iOS 26.0,*)){
            NSURL *folder=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"HengePipelines" isDirectory:YES];
            if(!pipeline_bundle)pipeline_bundle=[[HvPipelineBundle alloc]initWithDevice:device directory:folder];
            HvPipelineBundle *bundle=pipeline_bundle;
            metal4_screen=[[HvMetal4Screen alloc]initWithRuntime:metal4 device:device library:(bundle&&bundle->screenLibrary?bundle->screenLibrary:lib) bundle:pipeline_bundle];
            [metal4_screen setFXCacheLimit:atomic_load(&display_fx_limit)];
            fprintf(stderr,"hengevm: metal4-display: active=%d bundle_hits=%llu bundle_misses=%llu\n",metal4_screen!=nil,bundle?(unsigned long long)bundle->hits:0,bundle?(unsigned long long)bundle->misses:0);
        }}
        screen_pipe = hv_screen_pipeline(device, lib, @"screen_plain", NO, &err);
        linear_pipe = hv_screen_pipeline(device, lib, @"screen_linear", NO, &err);
        cursor_pipe = hv_screen_pipeline(device, lib, @"screen_cursor", YES, &err);
        fprintf(stderr, "hengevm: native-metal: device=%s display-library=%s pipelines_ms=%.2f cpu-frame-copy=0\n",
                device.name.UTF8String, bundled ? "precompiled" : "runtime-fallback", (now_seconds() - started) * 1000);
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        screen_sampler = [device newSamplerStateWithDescriptor:sd];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        cursor_sampler = [device newSamplerStateWithDescriptor:sd];
        if (!screen_pipe || !linear_pipe || !cursor_pipe || !screen_sampler || !cursor_sampler) { [self complain:[NSString stringWithFormat:@"screen pipelines: %@", err.localizedDescription]]; return NO; }
    }
    // Pipelines are shared, but a newly connected monitor has a fresh layer.
    if (prepared_layer != target) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        target.device = device;
        target.pixelFormat = MTLPixelFormatBGRA8Unorm;
        target.framebufferOnly = !(getenv("HV_PVG_GPU_TEST") || getenv("HV_COLOR_PROBE")); /* the probe copies the drawable out */
        target.allowsNextDrawableTimeout = YES;
        target.maximumDrawableCount = 3;
        [CATransaction commit];
        prepared_layer = target;
        fprintf(stderr, "hengevm: pvg-metal: half-float display surfaces are shown %s (HV_PVG_HALF=%s)\n",
                hv_half_mode_get() == 1 ? "as LINEAR light with an sRGB encode" : "as display-encoded values, passed through", hv_half_mode_get() == 1 ? "linear" : "encoded/default");
        if (cp.on) cp_log_layer(self, target);
    }
    return YES;
}

/* The display, drawn by the GPU. Waiting for a drawable can take until the screen's next
   refresh, so that happens on a thread of its own and never holds up the guest's GPU work:
   this only says what to show next. Whatever is newest when a drawable comes is what is shown. */
- (void)updatePacingPolicy {
    HvDisplaySettings settings = hv_display_settings_get();
        int cap = hv_pacing_power_fps(settings.presentation_cap, settings.thermal, settings.thermal_protection,settings.power_aware,settings.low_power);
        if (!pacing_policy_logged || cap != pacing_fps) {
            pacing_policy_logged = YES;
            fprintf(stderr, "hengevm: display-pacing: cap=%d thermal=%d low-power=%d aware=%d resolution=unchanged guest-rendering=unchanged\n", cap, settings.thermal,settings.low_power,settings.power_aware);
            pacing_fps = cap;
        }
}

- (CGSize)presentationSizeForWidth:(uint32_t)width height:(uint32_t)height {
    if(!desktop_fx)return CGSizeMake(width,height);
    uint32_t mw=0,mh=0;hv_pvg_lite_mode(&mw,&mh);
    HvDesktopOutput size=hv_desktop_output(width,height,mw,mh,desktop_fx?2:1);
    return CGSizeMake(size.width,size.height);
}

#if TARGET_OS_IPHONE
/* screen_lock held. Preflight stays on the existing presenter; display-link
   ownership stays on main. The same encoder consumes the supplied drawable. */
- (void)requestDisplayPulse {
    if (atomic_load(&stopping) || display_arm_pending || display_quiesced || !display_scene_active || !layer || !screen_dirty) return;
    CGSize output=[self presentationSizeForWidth:screen_w height:screen_h];
    if(display_pulse_active && display_link_layer==layer && display_link_generation==layer_generation &&
       display_prepared_w==output.width && display_prepared_h==output.height)return;
    display_arm_pending = YES;
    uint64_t generation = layer_generation;
    CAMetalLayer *target = layer;
    uint32_t width = (uint32_t)output.width, height = (uint32_t)output.height;
    __weak HvReplay *weak = self;
    dispatch_async(presenter, ^{
        HvReplay *owner = weak;
        if (!owner || atomic_load(&owner->stopping)) return;
        BOOL prepared = [owner prepareScreenForLayer:target];
        if (prepared) {
            [CATransaction begin]; [CATransaction setDisableActions:YES];
            target.drawableSize = CGSizeMake(width, height); [CATransaction commit];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            HvReplay *r = weak;
            if (!r) return;
            UIView *view = [target.delegate isKindOfClass:UIView.class] ? (UIView *)target.delegate : nil;
            UIWindowScene *scene = view.window.windowScene;
            BOOL visible = scene && scene.activationState == UISceneActivationStateForegroundActive && !view.hidden && view.alpha > 0;
            os_unfair_lock_lock(&r->screen_lock);
            if (generation != r->layer_generation || atomic_load(&r->stopping)) {
                os_unfair_lock_unlock(&r->screen_lock); return;
            }
            r->display_arm_pending = NO;
            r->display_scene_active = visible;
            if (!prepared || !visible || r->display_quiesced || !r->screen_dirty) {
                os_unfair_lock_unlock(&r->screen_lock); return;
            }
            CAMetalDisplayLink *previous = nil;
            if (!r->display_link || r->display_link_layer != target) {
                previous = r->display_link;
                HvDisplayPulse *delegate = [HvDisplayPulse new]; delegate.owner = r;
                CAMetalDisplayLink *link = [[CAMetalDisplayLink alloc] initWithMetalLayer:target];
                link.paused = YES; link.delegate = delegate;
                r->display_delegate = delegate; r->display_link = link; r->display_link_layer = target;
                [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            }
            r->display_link_generation = generation;
            r->display_prepared_w=width;r->display_prepared_h=height;
            [r updatePacingPolicy];
            float supported = view.window.screen.maximumFramesPerSecond;
            if (supported <= 0) supported = 60;
            float maximum = r->pacing_fps ? fminf(r->pacing_fps, supported) : supported;
            r->display_link.preferredFrameRateRange = CAFrameRateRangeMake(maximum,maximum,maximum);
            r->display_pulse_active=YES;r->display_link.paused=NO;
            os_unfair_lock_unlock(&r->screen_lock);
            [previous invalidate];
        });
    });
}
- (void)displayPulse:(CAMetalDisplayLink *)link update:(CAMetalDisplayLinkUpdate *)update {
    os_unfair_lock_lock(&screen_lock);
    BOOL current=link==display_link && layer_generation==display_link_generation;
    UIView *view=[layer.delegate isKindOfClass:UIView.class] ? (UIView *)layer.delegate : nil;
    UIWindowScene *scene=view.window.windowScene;
    BOOL visible=scene && scene.activationState==UISceneActivationStateForegroundActive && !view.hidden && view.alpha>0;
    if(current && !visible)display_scene_active=NO;
    if(!current || atomic_load(&stopping) || display_quiesced || !display_scene_active || !layer || !screen_dirty){
        if(current)display_pulse_active=NO;
        link.paused=YES;os_unfair_lock_unlock(&screen_lock);return;
    }
    [self updatePacingPolicy];
    float supported=view.window.screen.maximumFramesPerSecond;if(supported<=0)supported=60;
    float maximum=pacing_fps ? fminf(pacing_fps,supported) : supported;
    if(link.preferredFrameRateRange.maximum!=maximum)
        link.preferredFrameRateRange=CAFrameRateRangeMake(maximum,maximum,maximum);
    // CAMetalDisplayLink owns the cadence. A second deadline measured from
    // command commit is late by encoding time and can reject every other tick.
    // Keep one active stream of pulses while damaged; pause on the first idle
    // pulse, and never acquire another drawable while one is being encoded.
    if(atomic_load(&presentation_inflight)>=2)atomic_fetch_add(&presentation_backpressure,1);
    if(!presenter_running && !display_drawable && atomic_load(&presentation_inflight)<2){display_drawable=update.drawable;[self kickPresenter:NO];}
    os_unfair_lock_unlock(&screen_lock);
}
#endif

- (void)kickPresenter:(BOOL)fresh {
    /* screen_lock held */
    if (atomic_load(&stopping) || display_quiesced) return;
    if (fresh) screen_requests++;
    if (display_driven) {
#if TARGET_OS_IPHONE
        if (display_quiesced || !display_scene_active || presenter_running || !layer || !screen_tex) return;
        if (!display_drawable) { [self requestDisplayPulse]; return; }
        presenter_running = YES;
        dispatch_async(presenter, ^{ [self presentLoop]; });
#endif
        return;
    }
    if (presenter_running || !layer || !screen_tex || drawable_retry_pending || pacing_pending || atomic_load(&presentation_inflight)>=2) return;
    [self updatePacingPolicy];
    double now = now_seconds();
    double delay = hv_pacing_delay(&frame_pacing, now, pacing_fps);
    if (delay > 0) {
        pacing_pending = YES;
        frame_pacing.coalesced++;
        uint64_t generation = layer_generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), presenter, ^{
            os_unfair_lock_lock(&self->screen_lock);
            if (generation == self->layer_generation) {
                self->pacing_pending = NO;
                [self kickPresenter:NO];
            }
            os_unfair_lock_unlock(&self->screen_lock);
        });
        return;
    }
    if (drawable_retry_cooldown) {
        double delay = drawable_retry_cooldown - now_seconds();
        if (delay > 0) {
            if (!fresh) return;
            // Coalesce fresh work arriving during cooldown; it may be the guest's
            // last update. Automatic retries alone never reopen an exhausted budget.
            drawable_retry_pending = YES;
            uint64_t generation = layer_generation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), presenter, ^{
                os_unfair_lock_lock(&self->screen_lock);
                if (self->layer_generation == generation) {
                    self->drawable_retry_pending = NO;
                    self->drawable_retry_cooldown = self->drawable_retry_deadline = 0;
                    [self kickPresenter:NO];
                }
                os_unfair_lock_unlock(&self->screen_lock);
            });
            return;
        }
        drawable_retry_cooldown = drawable_retry_deadline = 0;
    }
    presenter_running = YES;
    dispatch_async(presenter, ^{ [self presentLoop]; });
}

/* Port one never modifies the primary layer, frame counters or guest completions.
   The consumer commits its snapshot on this very queue before the worker can
   submit another guest write. All link cursor state belongs to this worker. */
- (void)sendLinkMapping:(uint64_t)mapping {
    link_mapping=mapping;
    HvPvgLinkFrameHandler handler=link_frame_handler();
    HvObject *surface=surfaces[@(mapping)];
    if(!handler || !surface)return;
    if(!surface->scanout){
        BOOL half=surface->fourcc=='RGhA';
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:half ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm width:surface->surface_w height:surface->surface_h mipmapped:NO];
        d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
        surface->scanout=[(id<MTLBuffer>)surface->object newTextureWithDescriptor:d offset:surface->first bytesPerRow:surface->row];
    }
    if(!surface->scanout)return;
    const uint8_t *page=hv_pvg_lite_display_page_for_port(lite,1);
    uint32_t at=page ? __atomic_load_n((const uint32_t *)(page+0xe00),__ATOMIC_ACQUIRE) : UINT32_MAX;
    BOOL shown=page && at!=UINT32_MAX && (link_cursor_shown || page[0xe04]);
    float scale=cursor_scale(page,surface->surface_w);
    handler((__bridge void *)surface->scanout,(__bridge void *)queue,(uint32_t)hv_half_mode_get(),
            shown ? (__bridge void *)link_cursor : NULL,
            (float)(at&0xffff)-link_hx*scale,(float)(at>>16)-link_hy*scale,link_cw*scale,link_ch*scale);
}

/* Worker-owned optional capture. The consumer commits on the guest queue before
   another guest write; borrowed textures are retained through GPU completion. */
- (void)sendPrimaryMirror {
    if (atomic_load(&stopping)) return;
    HvPvgLinkFrameHandler handler=primary_frame_handler();if(!handler)return;
    os_unfair_lock_lock(&screen_lock);
    id<MTLTexture> tex=screen_tex,ctex=cursor_tex;
    BOOL shown=cursor_shown;
    uint32_t cw=cursor_w,ch=cursor_h,hx=cursor_hot_x,hy=cursor_hot_y;
    os_unfair_lock_unlock(&screen_lock);
    if(!tex)return;
    const uint8_t *page=hv_pvg_lite_display_page(lite);
    uint32_t at=page ? __atomic_load_n((const uint32_t *)(page+0xe00),__ATOMIC_ACQUIRE) : UINT32_MAX;
    BOOL visible=page && at!=UINT32_MAX && ctex && (shown || page[0xe04]);
    float scale=cursor_scale(page,(uint32_t)tex.width);
    handler((__bridge void *)tex,(__bridge void *)queue,(uint32_t)hv_half_mode_get(),visible ? (__bridge void *)ctex : NULL,
            (float)(at&0xffff)-hx*scale,(float)(at>>16)-hy*scale,cw*scale,ch*scale);
}
- (void)schedulePrimaryMirror {
    if(!primary_frame_handler() || atomic_exchange(&mirror_queued,1))return;
    dispatch_async(worker,^{atomic_store(&self->mirror_queued,0);[self sendPrimaryMirror];});
}

- (void)showOnLayer:(uint64_t)mapping {
    HvObject *surface = hv_pvg_lite_old_driver(lite) ? [self currentSurface:mapping] : (surfaces[@(mapping)] ?: [self newSurface:mapping]); /* not met yet: a resumed machine's screen */
    if (!surface) { [self complain:[NSString stringWithFormat:@"swap to unknown surface %llu", mapping]]; return; }
    on_screen = mapping;
    BOOL half = surface->fourcc == 'RGhA';
    if (!screen_tex) fprintf(stderr, "hengevm: display scanout format %s (%ux%u)\n",
                             half ? "RGBA16Float" : "BGRA8Unorm", surface->surface_w, surface->surface_h);
    if (!surface->scanout) {
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:half ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm
                                                                                     width:surface->surface_w height:surface->surface_h mipmapped:NO];
        t.storageMode = MTLStorageModeShared;
        t.usage = MTLTextureUsageShaderRead;
        if (linear_texture_fits(device, t, surface->first, surface->row, ((id<MTLBuffer>)surface->object).length))
            surface->scanout = [(id<MTLBuffer>)surface->object newTextureWithDescriptor:t offset:surface->first bytesPerRow:surface->row];
        if (!surface->scanout) { [self complain:[NSString stringWithFormat:@"no scanout for surface %llu, row %llu", mapping, surface->row]]; return; }
    }
    os_unfair_lock_lock(&screen_lock);
    screen_tex = surface->scanout, screen_half = half, screen_w = surface->surface_w, screen_h = surface->surface_h;
    screen_image_epoch++;
    screen_dirty = YES;
    [self kickPresenter:YES];
    os_unfair_lock_unlock(&screen_lock);
    [self sendPrimaryMirror];
}

/* The pointer moved or changed: the screen again, with no need to go through the GPU queue's worker. */
- (void)screenChanged {
    os_unfair_lock_lock(&screen_lock);
    if (screen_tex && !atomic_load(&stopping)) {
        const uint8_t *page = hv_pvg_lite_display_page(lite);
        uint32_t position = page ? __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE) : UINT32_MAX;
        HvDisplaySettings settings = hv_display_settings_get();
        HvCursorDamageKey key = {.layer=layer_generation,.glyph=cursor_revision,
            .position=position,.width=cursor_w,.height=cursor_h,.hot_x=cursor_hot_x,.hot_y=cursor_hot_y,
            .settings=(unsigned)cursor_scale_value(settings,page,screen_w) | (settings.sharp ? 4u : 0u),
            .visible=page && position != UINT32_MAX && cursor_tex && (cursor_shown || page[0xe04])};
        if (!hv_cursor_damage_changed(&cursor_damage, key)) { os_unfair_lock_unlock(&screen_lock); return; }
        screen_dirty = YES;
        [self kickPresenter:YES];
    }
    os_unfair_lock_unlock(&screen_lock);
    [self schedulePrimaryMirror];
}

- (void)presentLoop {
    for (;;) @autoreleasepool {
        os_unfair_lock_lock(&screen_lock);
        if (!screen_dirty || !layer || display_quiesced || (display_driven && !display_scene_active)) {
            presenter_running = NO;
            os_unfair_lock_unlock(&screen_lock);
            return;
        }
#if TARGET_OS_IPHONE
        id<CAMetalDrawable> supplied = nil;
        if (display_driven) {
            supplied = display_drawable; display_drawable = nil;
            if (!supplied) {
                presenter_running = NO;
                [self requestDisplayPulse];
                os_unfair_lock_unlock(&screen_lock); return;
            }
        }
#endif
        [self updatePacingPolicy];
        if (!display_driven && hv_pacing_delay(&frame_pacing, now_seconds(), pacing_fps) > 0) {
            presenter_running = NO;
            [self kickPresenter:NO];
            os_unfair_lock_unlock(&screen_lock);
            return;
        }
        if(atomic_load(&presentation_inflight)>=2){
            presentation_backpressure++;presenter_running=NO;
            os_unfair_lock_unlock(&screen_lock);return;
        }
        screen_dirty = NO;
        CAMetalLayer *target = layer; // retained across nextDrawable and a concurrent disconnect
        uint64_t generation = layer_generation, requests = screen_requests;
        id<MTLTexture> tex = screen_tex, ctex = cursor_tex;
        BOOL half = screen_half, shown = cursor_shown;
        uint32_t W = screen_w, H = screen_h, cw0 = cursor_w, ch0 = cursor_h;
        int hx = cursor_hot_x, hy = cursor_hot_y;
        os_unfair_lock_unlock(&screen_lock);
        if (![self prepareScreenForLayer:target]) {
            os_unfair_lock_lock(&screen_lock);
            BOOL changed = layer_generation != generation;
            if (!changed) presenter_running = NO;
            os_unfair_lock_unlock(&screen_lock);
            if (changed) continue;
            return;
        }
        CGSize want = [self presentationSizeForWidth:W height:H];
        uint32_t OW=(uint32_t)want.width,OH=(uint32_t)want.height;
        if (!CGSizeEqualToSize(target.drawableSize, want)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            target.drawableSize = want;
            [CATransaction commit];
        }
        id<CAMetalDrawable> drawable;
#if TARGET_OS_IPHONE
        drawable = display_driven ? supplied : [target nextDrawable];
#else
        drawable = [target nextDrawable];
#endif
        if (!drawable) {
            os_unfair_lock_lock(&screen_lock);
            screen_dirty = YES;
            BOOL changed = layer_generation != generation;
            if (!changed) {
                presenter_running = NO;
                double now = now_seconds();
                if (!drawable_retry_deadline) drawable_retry_deadline = now + 2;
                BOOL exhausted = now >= drawable_retry_deadline;
                if (exhausted) {
                    drawable_retry_cooldown = now + 1;
                    // A fresh frame/cursor event received while nextDrawable waited
                    // must not lose its wakeup at the transition into cooldown.
                    if (screen_requests != requests) [self kickPresenter:YES];
                } else {
                    // A monitor can connect before its first drawable is available.
                    // Retry even if the guest is idle, but never poll a hidden target forever.
                    drawable_retry_pending = YES;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), presenter, ^{
                        os_unfair_lock_lock(&self->screen_lock);
                        if (self->layer_generation == generation) {
                            self->drawable_retry_pending = NO;
                            [self kickPresenter:NO];
                        }
                        os_unfair_lock_unlock(&self->screen_lock);
                    });
                }
            }
            os_unfair_lock_unlock(&screen_lock);
            if (changed) continue;
            return;
        }
        /* Something newer came during the wait? Then that is the frame to show. */
        os_unfair_lock_lock(&screen_lock);
        tex = screen_tex, half = screen_half, ctex = cursor_tex, shown = cursor_shown;
        uint64_t imageEpoch=screen_image_epoch;
        cw0 = cursor_w, ch0 = cursor_h, hx = cursor_hot_x, hy = cursor_hot_y;
        BOOL same_target = layer_generation == generation && layer == target;
        BOOL same_size = screen_w == W && screen_h == H;
        if (display_driven) same_size = same_size && drawable.texture.width == OW && drawable.texture.height == OH;
        if (same_target && same_size) {
            screen_dirty = NO;
            drawable_retry_deadline = 0;
        }
        os_unfair_lock_unlock(&screen_lock);
        if (!same_target || !same_size) { /* a target or mode change during nextDrawable */
            os_unfair_lock_lock(&screen_lock);
            screen_dirty = YES;
            os_unfair_lock_unlock(&screen_lock);
            continue;
        }
        const uint8_t *page = hv_pvg_lite_display_page(lite);
        uint32_t where = page ? __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE) : 0xffffffff;
        BOOL showCursor=ctex && where!=0xffffffff && (shown||page[0xe04]);
        float cursorRect[4]={0};BOOL sharpCursor=NO;
        if(showCursor){
            const HvDisplaySettings cursorSettings=hv_display_settings_get();
            const float scale = cursor_scale_value(cursorSettings,page,W);
            float x = (float)(where & 0xffff) - hx * scale, y = (float)(where >> 16) - hy * scale;
            float cw = cw0 * scale, ch = ch0 * scale;
            /* The pointer's place is in the display mode's pixels, not the surface's: with a scaled resolution
               chosen in macOS (1280x988 on a 1864x1440 display) the surface is smaller than the mode, and the
               pointer was drawn further right and down than where it clicks. Seen on a phone: the pointer at
               1842 of 1864 with a 1600 wide surface, and the Dock's magnification under where it is drawn now.
               The guest stops the pointer 128 x (mode / surface - 1) pixels short of the right and bottom edges
               there and crops its image, while what it clicks goes on to the edge; open. */
            uint32_t MW = W, MH = H;
            hv_pvg_lite_mode(&MW, &MH);
            if (!MW || !MH) MW = W, MH = H;
            float r[4] = {x / MW * 2 - 1, 1 - (y + ch) / MH * 2, cw / MW * 2, ch / MH * 2};
            memcpy(cursorRect,r,sizeof cursorRect);sharpCursor=cursorSettings.sharp;
        }
        id displayJob=nil;
        if(metal4_screen && !cp.on && !getenv("HV_PVG_GPU_TEST")) {
            if(@available(macOS 26.0,iOS 26.0,*))displayJob=[metal4_screen encode:tex target:drawable.texture half:half mode:(uint32_t)hv_half_mode_get() cursor:showCursor?ctex:nil rect:showCursor?cursorRect:NULL sharp:sharpCursor imageEpoch:imageEpoch upscale:desktop_fx];
        }
        id<MTLCommandBuffer> cb=nil;
        if(!displayJob){
        cb = [queue commandBuffer];
        cb.label = @"Henge native display and cursor";
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            atomic_fetch_sub(&self->presentation_inflight,1);
            dispatch_group_leave(self->completions);
            dispatch_async(self->presenter, ^{os_unfair_lock_lock(&self->screen_lock);[self kickPresenter:NO];os_unfair_lock_unlock(&self->screen_lock);});
            if (done.status == MTLCommandBufferStatusError)
                fprintf(stderr, "hengevm: native-metal: display command failed: %s\n", done.error.description.UTF8String);
        }];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
        [e setRenderPipelineState:half ? linear_pipe : screen_pipe];
        float rect[4] = {-1, -1, 2, 2};
        [e setVertexBytes:rect length:sizeof rect atIndex:0];
        [e setFragmentTexture:tex atIndex:0];
        [e setFragmentSamplerState:screen_sampler atIndex:0];
        if (half) {
            uint32_t half_mode = (uint32_t)hv_half_mode_get();
            [e setFragmentBytes:&half_mode length:sizeof half_mode atIndex:0];
        }
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        if(showCursor){
            [e setRenderPipelineState:cursor_pipe];
            [e setVertexBytes:cursorRect length:sizeof cursorRect atIndex:0];
            [e setFragmentTexture:ctex atIndex:0];
            [e setFragmentSamplerState:sharpCursor?cursor_sampler:screen_sampler atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [e endEncoding];
        }
        if (cp.on) cp_capture_post(self, drawable.texture, OW, OH, cb);
#if !TARGET_OS_IPHONE
        if (getenv("HV_PVG_GPU_TEST")) { /* the same pixels for a screenshot: this is the path a phone runs */
            NSUInteger bytes = (NSUInteger)OW * OH * 4;
            if (!test_readback || test_readback.length < bytes) test_readback = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> rb = test_readback;
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(OW, OH, 1)
                      toBuffer:rb destinationOffset:0 destinationBytesPerRow:(NSUInteger)OW * 4 destinationBytesPerImage:bytes];
            [b endEncoding];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                (void)done;
                dispatch_async(self->worker, ^{
                    if (!self->frame || self->frame_w != OW || self->frame_h != OH) {
                        self->frame = malloc((size_t)OW * OH * 4), self->frame_w = OW, self->frame_h = OH;
                    }
                    memcpy(self->frame, rb.contents, (size_t)OW * OH * 4);
                    self->frames++;
                });
            }];
        }
#endif
        // Serialize the final check and commit with set_layer: a switch that has
        // returned must not be followed by a commit to its old target.
        os_unfair_lock_lock(&screen_lock);
        if (layer_generation == generation && layer == target && !display_quiesced && (!display_driven || display_scene_active)) {
            if (atomic_load_explicit(&frame_metrics_enabled,memory_order_relaxed)) {
                os_unfair_lock_lock(&frame_metrics_lock);uint64_t metrics_epoch=frame_metrics_epoch;os_unfair_lock_unlock(&frame_metrics_lock);
                double submitted_media_time=CACurrentMediaTime();
                [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
                    os_unfair_lock_lock(&self->frame_metrics_lock);
                    if(self->frame_metrics_epoch==metrics_epoch && atomic_load_explicit(&self->frame_metrics_enabled,memory_order_relaxed)) {
                        hv_frame_submission(&self->frame_metrics,generation,submitted_media_time,presented.presentedTime);
                        hv_frame_record(&self->frame_metrics,generation,presented.presentedTime);
                    }
                    os_unfair_lock_unlock(&self->frame_metrics_lock);
                }];
            }
            atomic_fetch_add(&presentation_inflight,1);
            dispatch_group_enter(completions);
            BOOL committed=YES;
            if(displayJob){
                BOOL queued=[metal4 commit:displayJob classicQueue:queue lock:&submission_lock drawable:drawable completion:^(BOOL ok){
                    if(!ok)atomic_fetch_add(&self->failed,1);
                    atomic_fetch_sub(&self->presentation_inflight,1);
                    dispatch_group_leave(self->completions);
                    dispatch_async(self->presenter, ^{os_unfair_lock_lock(&self->screen_lock);[self kickPresenter:NO];os_unfair_lock_unlock(&self->screen_lock);});
                }];
                if(@available(macOS 26.0,iOS 26.0,*))[metal4_screen didCommit:queued];
                if(!queued){committed=NO;atomic_fetch_sub(&presentation_inflight,1);dispatch_group_leave(completions);screen_dirty=YES;}
            }else{
                [cb presentDrawable:drawable];
                os_unfair_lock_lock(&submission_lock);[cb commit];os_unfair_lock_unlock(&submission_lock);
            }
            if(committed){gpu_frames++;hv_pacing_presented(&frame_pacing,now_seconds(),pacing_fps);}
        } else {
            if(displayJob){[metal4 discard:displayJob];if(@available(macOS 26.0,iOS 26.0,*))[metal4_screen didCommit:NO];}
            screen_dirty = YES;
        }
        os_unfair_lock_unlock(&screen_lock);
    }
}

/* What the display should show: at most a few times a second by CPU, for tests and the boot's first frames. */
- (void)present:(uint64_t)mapping {
    if (atomic_load(&stopping)) return;
    double now = now_seconds();
    on_screen = mapping;
    if ([self usesNativePresentation]) {
        late = NO;
        [self showOnLayer:mapping];
        return;
    }
    if (now - last_capture < 0.066) { /* 15 a second is plenty until this is GPU work */
        late_mapping = mapping, late = YES;
        if (!late_queued) {
            late_queued = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_MSEC), worker, ^{
                self->late_queued = NO;
                if (self->late) [self present:self->late_mapping];
            });
        }
        return;
    }
    late = NO;
    HvObject *surface = hv_pvg_lite_old_driver(lite) ? [self currentSurface:mapping] : (surfaces[@(mapping)] ?: [self newSurface:mapping]); /* not met yet: a resumed machine's screen */
    if (!surface) { [self complain:[NSString stringWithFormat:@"swap to unknown surface %llu", mapping]]; return; }
    last_capture = now;
    [last_cb waitUntilCompleted]; /* the CPU copies the pixels here, so the GPU must be done with them */
    NSUInteger bpp = surface->fourcc == 'RGhA' ? 8 : 4, row = surface->row;
    uint32_t w = surface->surface_w, h = surface->surface_h;
    if (!frame || !base || frame_w != w || frame_h != h) {
        free(base);
        base = malloc((size_t)w * h * 4);
        uint8_t *old = frame;
        frame = calloc((size_t)w * h, 4); /* the old one may be on screen for a moment yet: a small leak beats a crash */
        if (old) {
            if (!retired_frames) retired_frames = [NSMutableArray new];
            [retired_frames addObject:[NSValue valueWithPointer:old]];
        }
        frame_w = w, frame_h = h;
        drawn_w = drawn_h = 0;
    }
    uint8_t *out = base;
    const uint8_t *src = surface->mapped + surface->first;
    const uint8_t *lut = half_to_byte();
    if (bpp == 8) {
        for (uint32_t y = 0; y < h; y++) {
            const uint16_t *in = (const uint16_t *)(src + y * row);
            uint8_t *o = out + (size_t)y * w * 4;
            for (uint32_t x = 0; x < w; x++, in += 4, o += 4) {
                o[0] = lut[in[2]], o[1] = lut[in[1]], o[2] = lut[in[0]], o[3] = 255;
            }
        }
    } else {
        for (uint32_t y = 0; y < h; y++) memcpy(out + (size_t)y * w * 4, src + y * row, (size_t)w * 4);
    }
    memcpy(frame, base, (size_t)w * h * 4);
    drawn_w = drawn_h = 0;
    [self drawCursor];
    frames++;
}

#if !TARGET_OS_IPHONE
/* Debugging: HV_PVG_SHOT=prefix keeps what is on the display, every HV_PVG_SHOT_SECS seconds it has changed. */
- (void)saveShot {
    if (!frame || frames == frames_shot) return;
    frames_shot = frames;
    char path[1100];
    snprintf(path, sizeof path, "%s-%04u.png", shot, shots++);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(frame, frame_w, frame_h, 8, (size_t)frame_w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, img, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CFRelease(url), CGImageRelease(img), CGContextRelease(ctx), CGColorSpaceRelease(cs);
}
#endif

@end

HvPvgMetal *hv_pvg_metal_create(HvPvgLite *lite) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return NULL;
        if (![dev respondsToSelector:@selector(newRenderPipelineDescriptorWithSerializedData:deserializationContext:)]) {
            fprintf(stderr, "hengevm: pvg-metal: this Metal cannot read serialized pipelines; no drawing\n");
            return NULL;
        }
        Protocol *proto = objc_getProtocol("MTLDeserializationContext");
        if (proto) class_addProtocol([HvContext class], proto);
        HvReplay *r = [HvReplay new];
        r->lite = lite;
        r->desktop_fx=getenv("HV_PVG_DESKTOP_FX") && !strcmp(getenv("HV_PVG_DESKTOP_FX"),"2");
        if(r->desktop_fx)fprintf(stderr,"hengevm: desktop-metalfx: requested=2x scope=primary-desktop mode=1x-workspace quality=reconstructed fallback=linear\n");
        r->completions = dispatch_group_create();
        r->device = dev;
        r->queue = [dev newCommandQueueWithMaxCommandBufferCount:64];
        qos_class_t gpu_qos = hv_host_is_m4_16gb() ? QOS_CLASS_USER_INITIATED : QOS_CLASS_USER_INTERACTIVE;
        r->worker = dispatch_queue_create("hengevm.pvg", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, gpu_qos, 0));
        r->presenter = dispatch_queue_create("hengevm.present", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        r->screen_lock = OS_UNFAIR_LOCK_INIT;
        r->submission_lock=OS_UNFAIR_LOCK_INIT;
        if(!hv_env_flag("HV_METAL4_OFF") && (hv_host_is_m4_16gb()||hv_host_is_duo())) {
            if(@available(macOS 26.0,iOS 26.0,*))r->metal4=[[HvMetal4Runtime alloc]initWithDevice:dev];
        }
        fprintf(stderr,"hengevm: metal4-replay: available=%d classic-fallback=encoder-run; resources=explicit-residency ordering=two-way-shared-event commands=shared-bounded-parser\n",r->metal4!=nil);
        r->frame_metrics_lock = OS_UNFAIR_LOCK_INIT;
        r->display_scene_active = YES;
#if TARGET_OS_IPHONE
        r->display_driven = hv_host_is_m4_16gb() || hv_host_is_duo();
#endif
        r->frame_metrics_requested=getenv("HV_FRAME_STATS") && !strcmp(getenv("HV_FRAME_STATS"),"1");
        atomic_store(&r->frame_metrics_enabled,r->frame_metrics_requested);
        r->library_cache = [[HvMetalLibraryCache alloc] initWithMaxBytes:hv_env_flag("HV_GPU_LIBRARY_CACHE_OFF") ? 0 : 8 * 1024 * 1024 entries:32];
        r->gpu_timing = getenv("HV_GPU_TIMING") && !strcmp(getenv("HV_GPU_TIMING"), "1");
        r->diagnostics_enabled = getenv("HV_STATS") && atoi(getenv("HV_STATS")) > 0;
        r->bindings.disabled=hv_env_flag("HV_GPU_BINDING_CACHE_OFF");
        r->resource_tally = getenv("HV_PVG_TALLY") != NULL;
        r->batch_cache = getenv("HV_GPU_BATCH_CACHE") && !strcmp(getenv("HV_GPU_BATCH_CACHE"), "1");
        r->tasks = [NSMutableDictionary new];
        r->mapped_textures = [NSMutableDictionary new];
        r->surfaces = [NSMutableDictionary new];
        r->planar = [NSMutableDictionary new];
        r->complaints = [NSMutableSet new];
        [r refreshCacheBudget];
#if TARGET_OS_IPHONE
        __weak HvReplay *memory_owner = r;
        r->memory_pressure_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
            DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, r->worker);
        if (r->memory_pressure_source) {
            dispatch_source_set_event_handler(r->memory_pressure_source, ^{
                HvReplay *owner = memory_owner;
                if (!owner || atomic_load(&owner->stopping)) return;
                unsigned long flags = dispatch_source_get_data(owner->memory_pressure_source);
                owner->memory_pressure = flags & DISPATCH_MEMORYPRESSURE_CRITICAL ? 2 : flags & DISPATCH_MEMORYPRESSURE_WARN ? 1 : 0;
                [owner refreshCacheBudget];
            });
            dispatch_resume(r->memory_pressure_source);
        }
#endif
        fprintf(stderr, "gpu-capabilities: Apple9=%d max-buffer=%llu allocated=%llu (runtime capabilities; allocated size is not total process footprint)\n",
                [dev supportsFamily:MTLGPUFamilyApple9], (unsigned long long)dev.maxBufferLength, (unsigned long long)dev.currentAllocatedSize);
        r->shot = getenv("HV_PVG_SHOT");
        cp_start(r);
#if !TARGET_OS_IPHONE
        if (getenv("HV_PVG_GPU_TEST")) r->layer = [CAMetalLayer layer];
#endif
#if !TARGET_OS_IPHONE
        if (r->shot) {
            double every = getenv("HV_PVG_SHOT_SECS") ? atof(getenv("HV_PVG_SHOT_SECS")) : 5;
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, r->worker);
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(every * NSEC_PER_SEC)), (uint64_t)(every * NSEC_PER_SEC), NSEC_PER_SEC / 10);
            HvReplay *__weak weak = r;
            dispatch_source_set_event_handler(timer, ^{ [weak saveShot]; });
            dispatch_resume(timer);
            r->shot_timer = timer;
        }
#endif
        __weak HvReplay *weakReplay = r;
#if TARGET_OS_IPHONE
        void (^sceneChange)(NSNotification *) = ^(NSNotification *note) {
            HvReplay *owner = weakReplay;
            if (!owner || !owner->display_driven || atomic_load(&owner->stopping)) return;
            os_unfair_lock_lock(&owner->screen_lock);
            CAMetalLayer *target = owner->layer;
            os_unfair_lock_unlock(&owner->screen_lock);
            UIView *view = [target.delegate isKindOfClass:UIView.class] ? (UIView *)target.delegate : nil;
            if (view.window.windowScene != note.object) return;
            BOOL active = [note.name isEqualToString:UISceneDidActivateNotification];
            os_unfair_lock_lock(&owner->screen_lock);
            owner->display_scene_active = active;
            if(!active)owner->display_pulse_active=NO;
            if (active) { owner->screen_dirty = YES; [owner kickPresenter:YES]; }
            CAMetalDisplayLink *link = owner->display_link;
            os_unfair_lock_unlock(&owner->screen_lock);
            if (!active) link.paused = YES;
        };
        r->scene_activate_observer = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:sceneChange];
        r->scene_deactivate_observer = [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:sceneChange];
#endif
        r->settings_observer = [NSNotificationCenter.defaultCenter addObserverForName:@"HengeDisplaySettingsDidChange"
            object:nil queue:nil usingBlock:^(NSNotification *note) { (void)note; [weakReplay screenChanged]; }];
        fprintf(stderr, "hengevm: pvg-metal: drawing on %s\n", dev.name.UTF8String);
        return (HvPvgMetal *)CFBridgingRetain(r);
    }
}

void hv_pvg_metal_destroy(HvPvgMetal *m) {
    if (!m) return;
    @autoreleasepool {
        HvReplay *r = CFBridgingRelease(m);
        atomic_store(&r->stopping, 1);
        if(@available(macOS 26.0,iOS 26.0,*)){HvMetal4Runtime *runtime=r->metal4;if(runtime)[runtime->pipelineQueue setSuspended:YES];}
        if (r->settings_observer) { [NSNotificationCenter.defaultCenter removeObserver:r->settings_observer]; r->settings_observer = nil; }
        if (r->shot_timer) { dispatch_source_cancel(r->shot_timer); r->shot_timer = nil; }
        if (r->memory_pressure_source) { dispatch_source_cancel(r->memory_pressure_source); r->memory_pressure_source = nil; }
        if (cp.timer) { dispatch_source_cancel(cp.timer); cp.timer = nil; }
#if TARGET_OS_IPHONE
        if (r->scene_activate_observer) [NSNotificationCenter.defaultCenter removeObserver:r->scene_activate_observer];
        if (r->scene_deactivate_observer) [NSNotificationCenter.defaultCenter removeObserver:r->scene_deactivate_observer];
#endif
        os_unfair_lock_lock(&r->screen_lock);
        r->layer = nil;
        r->layer_generation++;
        r->screen_dirty = NO;
#if TARGET_OS_IPHONE
        CAMetalDisplayLink *retired_link = r->display_link;
        r->display_link = nil; r->display_delegate = nil; r->display_drawable = nil;r->display_pulse_active=NO;
#endif
        os_unfair_lock_unlock(&r->screen_lock);
#if TARGET_OS_IPHONE
        dispatch_async(dispatch_get_main_queue(), ^{ [retired_link invalidate]; });
#endif
        /* No CPU can enqueue more work. Delayed presentation blocks see
           stopping before touching guest memory; already queued work drains. */
        dispatch_sync(r->worker, ^{ r->late = NO; });
        dispatch_sync(r->presenter, ^{});
        {
            id<MTLCommandBuffer> fence = [r->queue commandBuffer];
            [fence commit];
            [fence waitUntilCompleted];
        }
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
        /* GPU completions may have enqueued a final readback on the worker. */
        dispatch_sync(r->worker, ^{
            [r saveArchive];
            [r dropArchiveMemory];
            r->lite = NULL;
            r->tasks = nil;
            r->surfaces = nil;
            r->mapped_textures = nil;
            r->planar = nil;
            r->screen_tex = nil;
            r->cursor_tex = nil;
            r->last_cb = nil;
            r->readback = r->test_readback = nil;
            free(r->frame); r->frame = NULL;
            free(r->base); r->base = NULL;
            free(r->cursor); r->cursor = NULL;
            for (NSValue *old in r->retired_frames) free(old.pointerValue);
            r->retired_frames = nil;
            free(cp.pend_src); cp.pend_src = NULL;
            cp.on = 0;
        });
    }
}

void hv_pvg_metal_submit(HvPvgMetal *m, HvPvgLite *lite, uint32_t ch, uint32_t *cmd, uint32_t len) {
    HvReplay *r = (__bridge HvReplay *)m;
    dispatch_async(r->worker, ^{
        @autoreleasepool {
            r->current_epoch = r->batch_cache ? ++r->command_epoch : 0;
            if (r->batch_cache && !r->current_epoch) { // epoch wrap cannot revive retained entries
                memset(r->object_keys, 0, sizeof r->object_keys);
            }
            uint32_t op = cmd[0] & 0xffff, skip = (cmd[0] >> 16) * 8; /* the barriers come first */
            const uint32_t *args = (const uint32_t *)((const uint8_t *)cmd + 12 + skip);
            uint32_t n = len > 12 + skip ? len - 12 - skip : 0;
            BOOL gpu_completes = NO;
            @try {
                if ((op == 0x43 || op == 0x45) && n >= 12) {
                    gpu_completes = [r exec:args length:n channel:ch stamp:cmd[2]];
                } else if (op == 0x37 && n >= 12) {
                    /* macOS 13's driver: the same work with 24-byte resource entries ({ref, flags} and four more words)
                       before the 16-byte buffers. Put it in 0x43's shape: {task, resources, buffers, {ref, flags}..., buffers...}. */
                    uint32_t nres = args[1], nbuf = args[2];
                    if (12 + nres * 24ull + nbuf * 16ull <= n && nres < 65536 && nbuf < 65536) {
                        uint32_t len43 = 12 + nres * 8 + nbuf * 16, *a43 = malloc(len43);
                        if (a43) {
                            a43[0] = args[0], a43[1] = nres, a43[2] = nbuf;
                            for (uint32_t i = 0; i < nres; i++) a43[3 + i * 2] = args[3 + i * 6], a43[4 + i * 2] = args[4 + i * 6];
                            memcpy(a43 + 3 + nres * 2, args + 3 + nres * 6, nbuf * 16ull);
                            gpu_completes = [r exec:a43 length:len43 channel:ch stamp:cmd[2]];
                            free(a43);
                        }
                    } else [r complain:[NSString stringWithFormat:@"command 0x37 of %u bytes: %u resources, %u buffers do not fit", n, nres, nbuf]];
                } else if ((op == 0x25 || op == 0x28) && n >= 8) { /* {task, ref} or {task, tag, size, ref} */
                    uint32_t ref = op == 0x25 ? args[1] : (n >= 16 ? args[3] : 0);
                    [r->tasks[@(args[0])] removeObjectForKey:@(ref)];
                } else if (op == 0x35 || op == 0x3e) {
                    [r synchronize:args length:n];
                } else if (op == 0x34) {
                    [r invalidate:args length:n];
                } else if (op == 0x3f) {
                    /* "May be thrown away": Apple's host only marks it purgeable, and the bytes stay
                       until the system needs the memory. Here they just stay. */
                } else if (op == 0x20 && n >= 4) {
                    /* PR133: delete sends a plain id; only define task shifts it. */
                    [r->tasks removeObjectForKey:@(args[0])];
                } else {
                    hv_pvg_lite_command(lite, cmd, len);
                    if (op == 8 && n >= 16) {
                        if (r->tracing) fprintf(stderr, "trace: swap to %llu\n", (uint64_t)args[3] << 32 | args[2]);
                        if(args[0]==0){
                            cp_note_swap(r, (uint64_t)args[3] << 32 | args[2], args, n);
                            [r present:(uint64_t)args[3] << 32 | args[2]];
                        } else if(args[0]==1) [r sendLinkMapping:(uint64_t)args[3]<<32|args[2]];
                    }
                    if (op == 4) [r cursorGlyph:args length:n];
                    if (op == 5 && n >= 8 && args[0]==1) {
                        r->link_cursor_shown=args[1]&1;[r sendLinkMapping:r->link_mapping];
                    }
                    if (op == 5 && n >= 8 && args[0]==0) {
                        os_unfair_lock_lock(&r->screen_lock);
                        r->cursor_shown = args[1] & 1;
                        os_unfair_lock_unlock(&r->screen_lock);
                        if (getenv("HV_PVG_CURSOR_LOG")) fprintf(stderr, "pvgcursor show %u\n", args[1]);
                        [r drawCursor];
                    }
                }
            } @catch (NSException *x) {
                [r complain:[NSString stringWithFormat:@"exception: %@", x.reason]];
            }
            r->current_epoch = 0;
            if (!gpu_completes) [r finishChannel:ch stamp:cmd[2]];
            free(cmd);
        }
    });
}

void hv_pvg_metal_set_layer(HvPvgMetal *m, void *layer) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    CAMetalLayer *l = (__bridge CAMetalLayer *)layer;
    // Invalidate immediately, even when the guest GPU worker has a backlog.
    os_unfair_lock_lock(&r->screen_lock);
    r->layer_generation++;
    if (r->frame_metrics_enabled) {
        os_unfair_lock_lock(&r->frame_metrics_lock);
        memset(&r->frame_metrics, 0, sizeof r->frame_metrics);
        r->frame_metrics.generation = r->layer_generation;
        os_unfair_lock_unlock(&r->frame_metrics_lock);
    }
    r->pacing_pending = NO; r->frame_pacing.next = 0; /* reattaching the same layer also wakes a stopped presenter */
    r->layer = l;
    r->native_output_selected = YES;
    r->display_arm_pending = NO;
    r->display_scene_active = YES; // the main-thread scene check verifies the new target
#if TARGET_OS_IPHONE
    r->display_drawable = nil;r->display_pulse_active=NO;
    CAMetalDisplayLink *retired_link = nil;
    if (r->display_link_layer != l) {
        retired_link = r->display_link; r->display_link = nil; r->display_delegate = nil;
    }
#endif
    r->drawable_retry_pending = NO;
    r->drawable_retry_deadline = r->drawable_retry_cooldown = 0;
    r->screen_dirty = YES;
    [r kickPresenter:YES];
    os_unfair_lock_unlock(&r->screen_lock);
#if TARGET_OS_IPHONE
    dispatch_async(dispatch_get_main_queue(), ^{ [retired_link invalidate]; });
#endif
    dispatch_async(r->worker, ^{
        if (r->on_screen) [r present:r->on_screen];
    });
}

void hv_pvg_metal_set_display_paused(HvPvgMetal *m, int paused) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    if(@available(macOS 26.0,iOS 26.0,*)){HvMetal4Runtime *runtime=r->metal4;if(runtime)[runtime->pipelineQueue setSuspended:paused!=0];}
    os_unfair_lock_lock(&r->screen_lock);
    r->display_quiesced = paused != 0;
#if TARGET_OS_IPHONE
    r->display_drawable = nil;r->display_pulse_active=NO;
    CAMetalDisplayLink *link = r->display_link;
#endif
    if (!paused) { r->screen_dirty = YES; [r kickPresenter:YES]; }
    os_unfair_lock_unlock(&r->screen_lock);
#if TARGET_OS_IPHONE
    if (paused) dispatch_async(dispatch_get_main_queue(), ^{ link.paused = YES; });
#endif
    if (paused) dispatch_sync(r->presenter, ^{}); // no presentation commit can cross the VM pause barrier
}

uint64_t hv_pvg_metal_gpu_frames(HvPvgMetal *m) {
    return m ? ((__bridge HvReplay *)m)->gpu_frames : 0;
}

int hv_pvg_metal_gpu_snapshot(HvPvgMetal *m,uint64_t out[4]) {
    if(!out)return 0;
    memset(out,0,4*sizeof *out);
    if(!m)return 0;
    HvReplay *r=(__bridge HvReplay *)m;
    out[0]=r->device.currentAllocatedSize;
    if(@available(macOS 26.0,iOS 26.0,*)){
        HvMetal4Runtime *runtime=r->metal4;
        if(runtime){
            out[1]=atomic_load_explicit(&runtime->completed,memory_order_relaxed);
            out[2]=atomic_load_explicit(&runtime->gpu_duration_ns,memory_order_relaxed);
            out[3]=atomic_load_explicit(&runtime->gpu_max_ns,memory_order_relaxed);
            return 2;
        }
    }
    return 1;
}

int hv_pvg_metal_capture_timing(HvPvgMetal *m,int capture,uint64_t out[4]) {
    if (!m) return 0;
    HvReplay *r=(__bridge HvReplay *)m;
    if(capture>=0){
        int previous=atomic_exchange_explicit(&r->capture_timing,!!capture,memory_order_relaxed);
        if(previous!=!!capture && !r->frame_metrics_requested){
            os_unfair_lock_lock(&r->screen_lock);
            os_unfair_lock_lock(&r->frame_metrics_lock);
            r->frame_metrics_epoch++;
            if(capture){memset(&r->frame_metrics,0,sizeof r->frame_metrics);r->frame_metrics.generation=r->layer_generation;}
            atomic_store_explicit(&r->frame_metrics_enabled,!!capture,memory_order_relaxed);
            os_unfair_lock_unlock(&r->frame_metrics_lock);
            os_unfair_lock_unlock(&r->screen_lock);
        }
    }
    if (out) {
        out[0]=atomic_load_explicit(&r->gpu_completed,memory_order_relaxed);
        out[1]=atomic_load_explicit(&r->gpu_duration_ns,memory_order_relaxed);
        out[2]=atomic_load_explicit(&r->gpu_max_ns,memory_order_relaxed);
        out[3]=atomic_load_explicit(&r->gpu_timing_missing,memory_order_relaxed);
    }
    return r->gpu_timing || atomic_load_explicit(&r->capture_timing,memory_order_relaxed) ? 2:1;
}

void hv_pvg_metal_cursor_moved(HvPvgMetal *m) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    if ([r usesNativePresentation]) { /* no need to queue behind the guest's GPU work */
        [r screenChanged];
        return;
    }
    static _Atomic int queued;
    if (atomic_exchange(&queued, 1)) return; /* one is already on its way, and it will read the newest position */
    dispatch_async(r->worker, ^{
        atomic_store(&queued, 0);
        [r drawCursor];
    });
}

void hv_pvg_metal_unmap(HvPvgMetal *m, uint32_t mapping) {
    HvReplay *r = (__bridge HvReplay *)m;
    dispatch_async(r->worker, ^{
        /* Mapping retirement releases its owner. Weak identity metadata expires
           after the final live surface/texture owner, including GPU work, leaves. */
        HvObject *s = r->surfaces[@(mapping)];
        if(s && s->planar_entry){
            hv_planar_release_mapping(r->planar,s->planar_key,s->planar_entry);
            s->planar_key=nil;s->planar_entry=nil;
        }
        [r->surfaces removeObjectForKey:@(mapping)];
        [r->mapped_textures removeObjectForKey:@(mapping)];
    });
}

/* A small picture of what the display shows, BGRA with no padding, for the app's home screen.
   Read straight from the surface's memory, nearest pixel: it may catch a frame being drawn, which
   does not matter at this size. -1 before anything has been shown. */
int hv_pvg_metal_snapshot(HvPvgMetal *m, uint8_t *bgra, uint32_t w, uint32_t h) {
    if (!m || !w || !h) return -1;
    HvReplay *r = (__bridge HvReplay *)m;
    os_unfair_lock_lock(&r->screen_lock);
    id<MTLTexture> tex = r->screen_tex;
    BOOL half = r->screen_half;
    uint32_t W = r->screen_w, H = r->screen_h;
    os_unfair_lock_unlock(&r->screen_lock);
    id<MTLBuffer> buffer = tex.buffer;
    if (!buffer || !W || !H || buffer.storageMode == MTLStorageModePrivate) return -1;
    const uint8_t *base = (const uint8_t *)buffer.contents + tex.bufferOffset;
    size_t row = tex.bufferBytesPerRow;
    /* Four samples to a pixel: one makes text look broken at this size. */
    for (uint32_t y = 0; y < h; y++) {
        uint8_t *out = bgra + (size_t)y * w * 4;
        for (uint32_t x = 0; x < w; x++, out += 4) {
            uint32_t sum[3] = {0, 0, 0};
            for (uint32_t k = 0; k < 4; k++) {
                size_t sx = (2 * x + (k & 1)) * (uint64_t)W / (2 * w), sy = (2 * y + (k >> 1)) * (uint64_t)H / (2 * h);
                const uint8_t *src = base + sy * row;
                if (!half) {
                    for (int c = 0; c < 3; c++) sum[c] += src[sx * 4 + c];
                    continue;
                }
                const __fp16 *p = (const __fp16 *)(src + sx * 8);
                for (int c = 0; c < 3; c++) {
                    float v = hv_half_shown((float)p[c], hv_half_mode_get()); /* as the screen shows it */
                    sum[2 - c] += (uint32_t)(v * 255 + 0.5f);
                }
            }
            for (int c = 0; c < 3; c++) out[c] = (uint8_t)((sum[c] + 2) / 4);
            out[3] = 255;
        }
    }
    return 0;
}

int hv_pvg_metal_frame(HvPvgMetal *m, const uint8_t **pixels, uint32_t *w, uint32_t *h) {
    if (!m) return -1;
    HvReplay *r = (__bridge HvReplay *)m;
    if (!r->frame) return -1;
    *pixels = r->frame, *w = r->frame_w, *h = r->frame_h;
    return 0;
}

void hv_pvg_metal_log_metrics(HvPvgMetal *metal) {
    if (!metal) return;
    HvReplay *r = (__bridge HvReplay *)metal;
    if (!r->frame_metrics_enabled) return;
    os_unfair_lock_lock(&r->frame_metrics_lock);
    struct HvFrameMetrics m = r->frame_metrics;
    if(r->desktop_fx && r->metal4_screen){if(@available(macOS 26.0,iOS 26.0,*)){
        HvMetal4Screen *screen=r->metal4_screen;
        fprintf(stderr,"desktop-metalfx: encoded=%llu cursor_cache_reuses=%llu fallbacks=%llu pressure_fallbacks=%llu resource_fallbacks=%llu geometry_fallbacks=%llu (presentation only; not game FPS or measured speedup)\n",(unsigned long long)atomic_load(&screen->fx_encoded),(unsigned long long)atomic_load(&screen->fx_reused),(unsigned long long)atomic_load(&screen->fx_fallback),(unsigned long long)atomic_load(&screen->fx_pressure_fallback),(unsigned long long)atomic_load(&screen->fx_resource_fallback),(unsigned long long)atomic_load(&screen->fx_size_fallback));
    }}
    os_unfair_lock_unlock(&r->frame_metrics_lock);
    fprintf(stderr, "frame-presented: epoch=%llu frames=%llu intervals=%llu elapsed_s=%.6f average_fps=%.3f p95_ms_upper=%.3f p99_ms_upper=%.3f low1_fps_estimate=%.3f max_ms=%.3f overflow=%llu invalid=%llu (host presentation incl cursor; 0.25ms bins; not game FPS)\n",
        (unsigned long long)m.generation, (unsigned long long)m.frames, (unsigned long long)m.intervals,
        m.last-m.first, m.total_ms ? 1000*m.intervals/m.total_ms : 0,
        hv_frame_percentile(&m,95), hv_frame_percentile(&m,99),hv_frame_low1(&m),m.max_ms,
        (unsigned long long)m.overflow,(unsigned long long)m.invalid);
    fprintf(stderr,"frame-submit-latency: epoch=%llu samples=%llu mean_ms=%.3f p95_ms_upper=%.3f p99_ms_upper=%.3f max_ms=%.3f not_presented=%llu invalid=%llu overflow=%llu (Core Animation media clock; commit-to-present callback timestamps; excludes no-work gaps, not guest FPS/input latency)\n",
        (unsigned long long)m.generation,(unsigned long long)m.latency_samples,
        m.latency_samples?m.latency_total_ms/m.latency_samples:0,
        hv_frame_bins_percentile(m.latency_bins,m.latency_samples,95),hv_frame_bins_percentile(m.latency_bins,m.latency_samples,99),m.latency_max_ms,
        (unsigned long long)m.not_presented,(unsigned long long)m.latency_invalid,(unsigned long long)m.latency_overflow);
}

void hv_pvg_metal_mirror_refresh(HvPvgMetal *m){
    if(!m)return;HvReplay *r=(__bridge HvReplay *)m;[r schedulePrimaryMirror];
}
void hv_pvg_metal_link_connected(HvPvgMetal *m,int connected){
    if(!m)return;HvReplay *r=(__bridge HvReplay *)m;
    dispatch_async(r->worker,^{
        if (atomic_load(&r->stopping)) return;
        hv_pvg_lite_apply_link_connected(r->lite,connected);
        if(connected)[r sendLinkMapping:r->link_mapping];
    });
}
void hv_pvg_metal_link_cursor_moved(HvPvgMetal *m){
    if(!m)return;HvReplay *r=(__bridge HvReplay *)m;
    if(atomic_exchange(&r->link_cursor_queued,1))return;
    dispatch_async(r->worker,^{atomic_store(&r->link_cursor_queued,0);if (!atomic_load(&r->stopping)) [r sendLinkMapping:r->link_mapping];});
}
void hv_pvg_metal_trim_memory(HvPvgMetal *m) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    dispatch_async(r->worker, ^{
        if (atomic_load(&r->stopping)) return;
        NSUInteger before = r->library_cache.count, bytes = r->library_cache.retainedBytes;
        r->cache_warnings++;
        r->cache_warning_until = now_seconds() + 30;
        /* Warning: shrink to the existing 8-entry/2MiB budget, retaining hot
           entries. Critical pressure/headroom still purges all cache owners.
           Live shaders/pipelines own their functions independently either way. */
        [r refreshCacheBudget];
        if (before != r->library_cache.count || bytes != r->library_cache.retainedBytes || r->cache_warnings == 1)
            fprintf(stderr, "hengevm: memory-pressure: Metal library cache %lu/%lu -> %lu/%lu entries/bytes; live surfaces and pipelines retained\n",
                    (unsigned long)before, (unsigned long)bytes,
                    (unsigned long)r->library_cache.count, (unsigned long)r->library_cache.retainedBytes);
    });
}

/* Pinned upstream Instant Resume entrypoints, adapted by the custom engine without a second replay. */
@interface HvReplay (Resume)
- (BOOL)page:(HvObject *)o toGuest:(BOOL)down task:(uint32_t)task blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb;
@end

/* Instant resume: the CPUs are stopped. Finish what the guest handed over, then copy what only the GPU holds (it drew
   into private memory and the guest has not asked for it back) into guest memory, where a replay made after a restore
   reads it from. A texture in a heap goes with its heap's bytes, as the heap is what is made again from guest memory. */
int hv_pvg_metal_quiesce(HvPvgMetal *m) {
    if (!m) return 0;
    HvReplay *r = (__bridge HvReplay *)m;
    __block int failed = 0;
    @autoreleasepool {
        dispatch_sync(r->worker, ^{});
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
        dispatch_sync(r->worker, ^{
            [r saveArchive];
            if (atomic_load(&r->failed)) failed = 1;
            id<MTLCommandBuffer> cb = nil;
            id<MTLBlitCommandEncoder> blit = nil;
            NSMutableArray<HvObject *> *copied = [NSMutableArray new];
            for (NSNumber *task in r->tasks) {
                NSMutableDictionary<NSNumber *, HvObject *> *objs = r->tasks[task];
                for (NSNumber *ref in objs) {
                    HvObject *o = objs[ref];
                    if (!o->guest_backed || !o->host_valid || !o->guest_stale) continue;
                    if (o->parent && o->parent->heap_whole) continue;
                    if (!cb) cb = [r->queue commandBuffer];
                    if (!cb || ![r page:o toGuest:YES task:task.unsignedIntValue blit:&blit commandBuffer:cb]) failed = 1;
                    else [copied addObject:o];
                }
            }
            [blit endEncoding];
            if (cb) {
                [cb commit];
                [cb waitUntilCompleted];
                if (cb.status != MTLCommandBufferStatusCompleted) failed = 1;
            }
            if (!failed) for (HvObject *o in copied) o->guest_stale = NO;
            fprintf(stderr, "hengevm: pvg-metal: quiesce %s, %lu GPU-only objects\n",
                    failed ? "failed (snapshot refused)" : "complete", (unsigned long)copied.count);
        });
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
    }
    return failed ? -1 : 0;
}

#include "display_snapshot.h"

size_t hv_pvg_metal_display_state(HvPvgMetal *m, void *out, size_t cap) {
    if (!m) return 0;
    HvReplay *r = (__bridge HvReplay *)m;
    __block size_t need = 0;
    dispatch_sync(r->worker, ^{
        os_unfair_lock_lock(&r->screen_lock);
        size_t primary = r->cursor ? (size_t)r->cursor_stride * r->cursor_h : 0;
        size_t secondary = r->link_cursor ? (size_t)r->link_cw * 4 * r->link_ch : 0;
        need = sizeof(HvDisplaySnapshot) + primary + secondary;
        if (out && cap >= need) {
            HvDisplaySnapshot d = {.version = HV_DISPLAY_SNAPSHOT_VERSION, .ports = 2};
            d.port[0] = (HvDisplaySnapshotPort){r->on_screen,
                primary ? r->cursor_w : 0, primary ? r->cursor_h : 0,
                primary ? r->cursor_stride : 0, r->cursor_shown != 0,
                r->cursor_hot_x, r->cursor_hot_y};
            d.port[1] = (HvDisplaySnapshotPort){r->link_mapping,
                secondary ? r->link_cw : 0, secondary ? r->link_ch : 0,
                secondary ? r->link_cw * 4 : 0, r->link_cursor_shown != 0,
                (int32_t)r->link_hx, (int32_t)r->link_hy};
            memcpy(out, &d, sizeof d);
            uint8_t *pixels = (uint8_t *)out + sizeof d;
            if (primary) memcpy(pixels, r->cursor, primary);
            if (secondary) [r->link_cursor getBytes:pixels + primary bytesPerRow:d.port[1].stride
                fromRegion:MTLRegionMake2D(0, 0, d.port[1].width, d.port[1].height) mipmapLevel:0];
        }
        os_unfair_lock_unlock(&r->screen_lock);
    });
    return need;
}

int hv_pvg_metal_set_display_state(HvPvgMetal *m, const void *in, size_t len) {
    HvDisplaySnapshot d;
    size_t bytes[2];
    if (!m || hv_display_snapshot_parse(in, len, &d, bytes)) return -1;
    uint8_t *copy = bytes[0] ? malloc(bytes[0]) : NULL;
    if (bytes[0] && !copy) return -1;
    const size_t *sizes = bytes;
    const uint8_t *pixels = (const uint8_t *)in + sizeof d;
    if (copy) memcpy(copy, pixels, bytes[0]);
    HvReplay *r = (__bridge HvReplay *)m;
    __block int failed = 0;
    dispatch_sync(r->worker, ^{
        @autoreleasepool {
            id<MTLTexture> glyphs[2] = {nil, nil};
            for (unsigned p = 0; p < 2; p++) if (sizes[p]) {
                const HvDisplaySnapshotPort *port = &d.port[p];
                MTLTextureDescriptor *ct = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                    width:port->width height:port->height mipmapped:NO];
                ct.storageMode = MTLStorageModeShared;
                glyphs[p] = [r->device newTextureWithDescriptor:ct];
                if (!glyphs[p]) { failed = 1; return; }
                [glyphs[p] replaceRegion:MTLRegionMake2D(0, 0, port->width, port->height) mipmapLevel:0
                    withBytes:pixels + (p ? sizes[0] : 0) bytesPerRow:port->stride];
            }
            os_unfair_lock_lock(&r->screen_lock);
            free(r->cursor);
            r->cursor = copy;
            r->cursor_w = d.port[0].width; r->cursor_h = d.port[0].height;
            r->cursor_stride = d.port[0].stride;
            r->cursor_hot_x = d.port[0].hot_x; r->cursor_hot_y = d.port[0].hot_y;
            r->cursor_shown = d.port[0].shown; r->cursor_tex = glyphs[0]; r->cursor_revision++;
            r->link_cursor = glyphs[1];
            r->link_cw = d.port[1].width; r->link_ch = d.port[1].height;
            r->link_hx = d.port[1].hot_x; r->link_hy = d.port[1].hot_y;
            r->link_cursor_shown = d.port[1].shown;
            os_unfair_lock_unlock(&r->screen_lock);
            r->on_screen = d.port[0].mapping; r->link_mapping = d.port[1].mapping;
            if (r->on_screen) [r present:r->on_screen];
            [r drawCursor];
            /* The transport remains disconnected until its normal new-session handshake. */
        }
    });
    if (failed) free(copy);
    return failed ? -1 : 0;
}
