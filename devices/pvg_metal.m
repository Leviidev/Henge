/* Runs the guest's GPU commands on the host's Metal, on any Apple platform.
   The guest driver serializes Metal calls: an exec names command buffers in a
   task's memory, each a segment holding {tag, size} records, one per call, in
   the formats worked out from the guest driver and listed by the decoders
   below. Objects are named by a number (a ref); the task's object list says
   what each is, and they are made the first time they are used. */

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>
#include <os/lock.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <TargetConditionals.h>
#import <IOSurface/IOSurfaceRef.h>
#import <CommonCrypto/CommonDigest.h>
#include <string.h>
#include <sys/utsname.h>

/* 1080p shrunk onto a phone would make a normal pointer a few dots across; an iPad's screen needs less. */
static int cursor_scale(void) {
#if TARGET_OS_IPHONE
    NSInteger saved = [[NSUserDefaults standardUserDefaults] integerForKey:@"henge.cursor.scale"];
    if (saved >= 1 && saved <= 3) return (int)saved;
    static int defaultScale;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct utsname u;
        uname(&u);
        defaultScale = strncmp(u.machine, "iPad", 4) ? 3 : 1;
    });
    return defaultScale;
#else
    return 1;
#endif
}

#include <mach/mach.h>
#include <stdatomic.h>
#include <mach/vm_map.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pvg_lite.h"
#include "lifecycle_gate.h"
#include "metallib.h"
#include "pvg_texture_record.h"
#include "pvg_surface_pages.h"
#include "pvg_surface_copyback.h"
#include "pvg_store_action.h"
#include "pvg_viewport_replay.h"
#include "pvg_replay_queue.h"
#include "pvg_render_status.h"
#if TARGET_OS_IPHONE
#include "pvg_shader_broker.h"
#import "HGOnDeviceShaderProvider.h"
#include "pvg_shader_profile.h"
#include "pvg_agx_journal.h"
#endif

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

static const void *surface_read_physical(void *context, uint64_t address, uint64_t length) {
    return hv_pvg_lite_phys((HvPvgLite *)context, address, length);
}

/* What is known about a made object, so a reused ref is noticed. */
@interface HvObject : NSObject {
@public
    id object;
    uint32_t entry[3];
    /* A buffer's guest pages, mapped contiguously. */
    uint8_t *mapped;
    BOOL mapping_in_buffer; /* the buffer over them frees them */
    BOOL plain_buffer; /* the object is that buffer */
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
    uint8_t described[0x200]; /* a surface: the older driver's compact description it was made from */
    uint64_t on_mapping; /* a mapped texture: the surface id it is over */
    /* A surface: */
    HvObject *surface;
    uint32_t surface_plane; /* also carried by texture views of this plane */
    uint64_t mapped_id; /* IOSurface mapper ID for an OBJ_MAPPED_TEXTURE */
    uint64_t row;
    uint32_t first;
    uint32_t surface_w, surface_h, fourcc; /* its own, whatever views the guest makes of it */
    id<MTLTexture> scanout; /* the same pixels, as the display reads them */
    /* Surfaces that cannot sit on a linear Metal buffer use a copied IOSurface. */
    IOSurfaceRef iosurface;
    uint64_t alloc;
    id<MTLBuffer> surface_shadow_buffer;
    uint8_t *surface_shadow; /* shared buffer: last uploaded or GPU-copied guest contents */
    BOOL surface_shadow_valid;
    __weak id<MTLCommandBuffer> surface_pending; /* only this surface's preceding copyback */
    /* Source layout of each copied plane in the guest's pages. */
    uint32_t plane_count;
    uint64_t plane_from[4], plane_row[4], plane_h[4], plane_w[4], plane_bpe[4];
    HvObject *surface_owner; /* shared IOSurface pixels and copyback state */
    id<MTLTexture> plane_textures[4]; /* canonical full-plane views, never HvObject parents */
    /* A heap: private memory, a buffer over all of it. */
    id<MTLBuffer> heap_whole;
    /* A heap's or a private texture's copy in guest memory, and which side has the newest bytes. */
    id<MTLBuffer> guest_copy;
    BOOL host_valid, guest_stale;
    /* What this one is made from, kept for as long as it lives. */
    HvObject *parent;
    /* A multi-plane surface's key in the replay's planar table, while it counts as one of its users. */
    NSString *planar_key;
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

/* Worker-owned object identities must not survive a task lifetime. Root-ring
   creates are noticed through the device creation epoch as well. */
static void task_cache_generation(NSMutableDictionary *tasks, uint64_t *seen,
                                  uint32_t task, uint64_t generation) {
    if (seen[task] != generation) {
        [tasks removeObjectForKey:@(task)];
        seen[task] = generation;
    }
}

static BOOL task_cache_lifecycle(NSMutableDictionary *tasks, uint32_t op,
                                 const uint32_t *args, uint32_t n) {
    if (op == 0x20 && n >= 4) {
        /* Destroy carries the direct task ID; only create encodes ID << 1. */
        [tasks removeObjectForKey:@(args[0])];
        return YES;
    }
    if (op == 0x38 && n >= 16) {
        [tasks removeObjectForKey:@(args[0] >> 1)];
        return YES;
    }
    return NO;
}

@class HvContext;

@interface HvReplay : NSObject {
@public
    HvPvgLite *lite;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    dispatch_queue_t worker;
    HvOrderedReplay *ordered;
    HvRenderStatus *renderStatus;
#if TARGET_OS_IPHONE
    HGOnDeviceShaderProvider *shaderProvider;
    NSString *shaderProviderError;
#endif
    HvReplayCommand *activeCommand;
    BOOL preflighting,preflightWaiting,pollScheduled;
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, HvObject *> *> *tasks;
    uint64_t task_generations[512]; /* worker-owned cache epochs */
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *mapped_textures;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *fallback_textures;
    NSMutableSet<NSNumber *> *scanout_mappings;
    id<MTLTexture> seeded_target_since_present;
    id<MTLTexture> last_fallback_scanout;
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *probe_targets;
    uint32_t probe_samples;
    NSMutableDictionary<NSNumber *, HvObject *> *surfaces;
    /* Multi-plane surfaces' host IOSurfaces by the guest memory they stand for: each process maps a surface
       under its own mapping id, and what one draws (macOS 27's WebKit draws pages into b3a8 tiles in its GPU
       process) has to be what another reads (WindowServer). */
    NSMutableDictionary<NSString *, id> *planar;
    NSMutableDictionary<NSString *, NSNumber *> *planar_uses; /* mappings using each: the entry goes with the last one */
    NSMutableSet<NSString *> *complaints;
    uint64_t execs, draws, failed, heap_bytes, synced, remaps;
    /* Work the GPU has not finished. Stamps are given back in the order they came: the
       GPU's completion handlers run in the order of commit. */
    _Atomic int inflight;
    _Atomic int stopping;
    dispatch_group_t completions;
    id<MTLCommandBuffer> last_cb;
    double encode_time, gpu_wait_time;
    BOOL pipeline_set; /* in the open encoder */
    HvPvgViewportReplay *viewport_replay;
    id<MTLComputePipelineState> active_compute_state;
    NSMutableArray *compute_audits;
    BOOL tess_factors; /* so is a tessellation factor buffer */
    uint32_t pre_raster_samples, pre_imageblock, pre_threadgroup, pre_tile_w, pre_tile_h; /* for the next pass */
    BOOL tracing; /* HV_PVG_TRACE_FILE exists: say what each exec draws */
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
    double shader_retry_check;
    /* A frame that came too soon after the last: shown shortly, for it may be the last for a long while. */
    uint64_t late_mapping;
    BOOL late, late_queued;
    uint64_t frames, frames_shot;
    /* Showing frames with the GPU: a layer the app gave us. No copies, no conversion on a CPU. */
    CAMetalLayer *layer; /* screen_lock protects the target and its generation */
    uint64_t layer_generation;
    __weak CAMetalLayer *prepared_layer; /* presenter only: each target needs its own setup */
    id<MTLRenderPipelineState> screen_pipe, linear_pipe, cursor_pipe;
    id<MTLFunction> stand_in; /* computeStandIn */
    id<MTLTexture> cursor_tex;
    id<MTLSamplerState> screen_sampler, cursor_sampler;
    uint64_t on_screen; /* the mapping showing */
    _Atomic uint64_t gpu_frames;
    dispatch_queue_t presenter;
    os_unfair_lock screen_lock; /* what to show, and the pointer as the presenter reads it */
    id<MTLTexture> screen_tex;
    BOOL screen_half, screen_dirty, presenter_running;
    BOOL presenter_barrier; /* screen_lock: mapper/drain waits cannot admit later presentation */
    BOOL drawable_retry_pending;
    double drawable_retry_cooldown; /* fresh work coalesces one wake at its expiry */
    uint64_t screen_requests; /* fresh frames/cursor changes, not automatic retries */
    double drawable_retry_deadline; /* at most two seconds of retrying an unavailable target */
    uint32_t screen_w, screen_h;
    id<MTLBuffer> test_readback; /* HV_PVG_GPU_TEST: the drawable's pixels for screenshots */
    id<MTLBuffer> readback;
    const char *shot;
    unsigned shots;
    dispatch_source_t shot_timer;
}
- (void)complain:(NSString *)what;
- (void)pumpCommands;
- (void)performCommand:(HvReplayCommand *)item;
- (int)shaderRead:(uint64_t)offset task:(uint32_t)task to:(void *)to length:(uint32_t)length;
- (HvObject *)object:(uint32_t)ref task:(uint32_t)task;
- (void)drawCursor;
- (BOOL)hasDisplayLayer;
- (void)kickPresenter:(BOOL)fresh;
- (void)present:(uint64_t)mapping;
- (void)screenChanged;
- (void)makePrivateMappedTexture:(HvObject *)o descriptor:(MTLTextureDescriptor *)t mapping:(uint64_t)mapping;
@end

/* What Metal asks while it reads a serialized pipeline. */
/* All commits, including helper clears, participate in the completion group.
   No gate mutex is held over a driver call, and the UI never waits here. */
static BOOL lifecycle_commit(HvReplay *r, id<MTLCommandBuffer> cb, BOOL wait) {
    for (;;) {
        if (wait && !hv_lifecycle_wait_stoppable(&hv_app_lifecycle, &r->stopping)) return NO;
        if (atomic_load(&r->stopping) || atomic_load(&hv_app_lifecycle.cancelled)) return NO;
        if (!hv_lifecycle_allowed(&hv_app_lifecycle)) {
            if (wait) continue;
            return NO;
        }
        atomic_fetch_add(&r->inflight, 1);
        dispatch_group_enter(r->completions);
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)done;
            atomic_fetch_sub(&r->inflight, 1);
            dispatch_group_leave(r->completions);
        }];
        [cb commit];
        if (wait) [cb waitUntilScheduled]; /* presenter waits after releasing screen_lock */
        return YES;
    }
}

@interface HvContext : NSObject {
@public
    __unsafe_unretained HvReplay *replay;
    uint32_t task;
    NSString *failure;
    id standIn; /* what a failed function lookup returns: nil, except for compute pipelines (makeSerialized) */
    NSMutableDictionary *auditFunctions; /* opt-in serialized-pipeline replay bindings */
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
    case MTLPixelFormatBGR10A2Unorm: return 4;
    case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm:
    case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float: return 8;
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
    BOOL ok = row >= t.width * bpp && (!align || (row % align == 0 && offset % align == 0)) && offset + row * t.height <= length;
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
    uint64_t n = (o->length + 0x3fff) >> 14;
    uint32_t stack[256];
    uint32_t *now = n <= 256 ? stack : malloc(n * 4);
    hv_pvg_lite_task_pages(r->lite, task, o->vpage, n, now);
    BOOL same = memcmp(now, o->pages, n * 4) == 0;
    if (now != stack) free(now);
    if (same) return;
    uint8_t *old = o->mapped;
    BOOL old_in_buffer = o->mapping_in_buffer;
    if (!map_pages(r, task, o)) return;
    if (!old_in_buffer) vm_deallocate(mach_task_self(), (vm_address_t)old, n << 14);
    o->mapping_in_buffer = NO;
    o->generation++;
    o->guest_copy = nil;
    if (o->plain_buffer) o->object = buffer_over_mapping(r, o);
    r->remaps++;
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
    HvObject *o = [replay object:(uint32_t)ref task:task];
    if (!o || !o->object) {
        if (!failure) failure = [NSString stringWithFormat:@"function %llu", ref];
        return standIn;
    }
    if (auditFunctions && [o->object respondsToSelector:@selector(functionType)]) {
        id<MTLFunction> function = o->object;
        auditFunctions[[NSString stringWithFormat:@"%llu", ref]] = @{
            @"name": function.name ?: @"",
            @"function_type": @(function.functionType),
            @"library_identity": objc_getAssociatedObject(function, "hvLibraryID") ?: @"unknown",
            @"reference_u64": [NSString stringWithFormat:@"%llu",ref],
            @"resolved_reference_u32": @((uint32_t)ref),
            @"object_entry_kind": @(o->entry[0] & 0xff),
            @"object_entry_size": @(o->entry[0] >> 8),
            @"host_class": NSStringFromClass([o->object class])
        };
    }
    return o->object;
}
@end

#if TARGET_OS_IPHONE
/* Keep the input BEFORE entering the driver. Post-call error capture cannot
   diagnose a driver trap. One atomic record bounds storage; replay is serial.
   "entered_driver" is an unfinished attempt, never a failed/successful result. */
static void capture_pipeline_attempt(NSData *bytes, NSDictionary *functions,
                                     uint32_t tag, uint32_t task, NSString *phase) {
    if (!functions || bytes.length > 1024 * 1024 || functions.count > 256) return;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (![NSFileManager.defaultManager fileExistsAtPath:[documents stringByAppendingPathComponent:@"shader-audit-capture"]]) return;
    NSDictionary *record = @{@"schema":@1, @"phase":phase, @"task":@(task), @"tag":@(tag),
        @"process_id":@(getpid()), @"timestamp":@([NSDate date].timeIntervalSince1970),
        @"serialized_base64":[bytes base64EncodedStringWithOptions:0], @"function_refs":functions};
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    [json writeToFile:[documents stringByAppendingPathComponent:@"shader-pipeline-last-attempt.json"]
             options:NSDataWritingAtomic error:nil];
}

static void capture_pipeline_descriptor(NSData *bytes, NSDictionary *functions, uint32_t tag, BOOL created, NSError *error) {
    if (!functions) return;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSUInteger capturedCount, capturedBytes;
    if (bytes.length > 1024 * 1024 || functions.count > 256) return;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (![NSFileManager.defaultManager fileExistsAtPath:[documents stringByAppendingPathComponent:@"shader-audit-capture"]]) return;
    NSString *folder = [documents stringByAppendingPathComponent:@"shader-pipeline-audit"];
    uint8_t hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
    NSMutableString *blobDigest = [NSMutableString new];
    for (unsigned i = 0; i < sizeof hash; i++) [blobDigest appendFormat:@"%02x", hash[i]];
    NSData *bindings = [NSJSONSerialization dataWithJSONObject:functions options:NSJSONWritingSortedKeys error:nil];
    if (!bindings) return;
    /* Numeric references can be reused by different guest tasks. A raw blob
       hash alone can therefore collapse pipelines bound to different shaders. */
    NSMutableData *identity = [[blobDigest stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
    [identity appendData:bindings];
    CC_SHA256(identity.bytes, (CC_LONG)identity.length, hash);
    NSMutableString *digest = [NSMutableString new];
    for (unsigned i = 0; i < sizeof hash; i++) [digest appendFormat:@"%02x", hash[i]];
    NSString *base = [folder stringByAppendingPathComponent:digest];
    NSFileManager *files = NSFileManager.defaultManager;
    if ([files fileExistsAtPath:[base stringByAppendingPathExtension:@"json"]]) return;
    os_unfair_lock_lock(&lock);
    BOOL allowed = capturedCount < 512 && capturedBytes + bytes.length <= 16 * 1024 * 1024;
    if (allowed) { capturedCount++; capturedBytes += bytes.length; }
    os_unfair_lock_unlock(&lock);
    if (!allowed) return;
    NSError *writeError = nil;
    if (![files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&writeError]) return;
    if (![bytes writeToFile:[base stringByAppendingPathExtension:@"bin"] options:NSDataWritingAtomic error:&writeError]) return;
    NSDictionary *record = @{@"schema":@2, @"sha256":digest, @"blob_sha256":blobDigest,
        @"bindings_data_base64":[bindings base64EncodedStringWithOptions:0], @"byte_size":@(bytes.length),
        @"tag":@(tag), @"function_refs":functions, @"state_created":@(created),
        @"pipeline_error":created ? @"" : (error.description ?: @""), @"host_os":NSProcessInfo.processInfo.operatingSystemVersionString};
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:&writeError];
    if (json && [json writeToFile:[base stringByAppendingPathExtension:@"json"] options:NSDataWritingAtomic error:&writeError])
        fprintf(stderr, "hengevm: pvg-metal: captured pipeline audit %s tag=%u created=%d\n", digest.UTF8String, tag, created);
}
#endif

@implementation HvReplay

- (void)complain:(NSString *)what {
    /* Replay and the display presenter can report errors concurrently. Keep
       deduplication atomic without holding this lock during Metal calls. */
    @synchronized (complaints) {
        if ([complaints containsObject:what]) return;
        [complaints addObject:what];
    }
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

#if TARGET_OS_IPHONE
/* Retain the exact verified result for this batch, independent of provider LRU. */
- (HGOnDeviceShaderResult *)retainLocalResult:(HGOnDeviceShaderResult *)result source:(NSString *)source {
    if(result.status!=HGOnDeviceShaderReady)return result;
    if(![result.sourceSHA isEqual:source]||!hv_shader_profile_validate(result.receipt,result.output,source,result.recipe,NULL)){
        activeCommand->error=@"The local shader result failed identity/profile verification.";return nil;
    }
    HGOnDeviceShaderResult *retained=activeCommand->localResults[source];if(retained)return retained;
    NSData *pending=activeCommand->localSources[source];
    if(pending){activeCommand->snapshotBytes-=pending.length;[activeCommand->localSources removeObjectForKey:source];}
    if(result.output.length>(128u<<20)-MIN(activeCommand->snapshotBytes,(NSUInteger)(128u<<20))){
        activeCommand->error=@"The required shader results exceed the graphics snapshot budget.";return nil;
    }
    activeCommand->snapshotBytes+=result.output.length;activeCommand->localResults[source]=result;
    return result;
}

- (HGOnDeviceShaderResult *)requestLocalShader:(NSData *)source sourceSHA:(NSString *)sourceSHA {
    HGOnDeviceShaderResult *result=activeCommand->localResults[sourceSHA];if(result)return result;
    if(!shaderProvider){activeCommand->error=shaderProviderError?:@"The local shader compiler is unavailable.";return nil;}
    result=[shaderProvider snapshotForSourceSHA:sourceSHA];
    if(result.status==HGOnDeviceShaderReady)return [self retainLocalResult:result source:sourceSHA];
    if(result.status==HGOnDeviceShaderFailed){activeCommand->error=result.error.localizedDescription?:@"The local shader compiler rejected this shader.";return result;}
    if(!activeCommand->localSources[sourceSHA]){
        if(source.length>(128u<<20)-MIN(activeCommand->snapshotBytes,(NSUInteger)(128u<<20))){
            activeCommand->error=@"The pending shader inputs exceed the graphics snapshot budget.";return nil;
        }
        activeCommand->localSources[sourceSHA]=[source copy];activeCommand->snapshotBytes+=source.length;
    }
    if([result.route isEqual:@"not-requested"]||[result.route isEqual:@"backpressure"]){
        __weak HvReplay *weak=self;
        result=[shaderProvider requestSource:source sourceSHA:sourceSHA completionQueue:worker completion:^{
            HvReplay *r=weak;if(r&&!atomic_load(&r->stopping))[r pumpCommands];
        }];
    }
    if(result.status==HGOnDeviceShaderReady)return [self retainLocalResult:result source:sourceSHA];
    if(result.status==HGOnDeviceShaderFailed)activeCommand->error=result.error.localizedDescription?:@"The local shader compiler rejected this shader.";
    return result;
}
#endif

- (id)makeFunction:(uint64_t)at task:(uint32_t)task {
    if (getenv("HV_PVG_FAIL_LIBS")) { /* testing: every library refused, as an OS that cannot load them does */
        [self complain:@"library: refused (HV_PVG_FAIL_LIBS)"];
        return nil;
    }
    struct __attribute__((packed)) { uint64_t off; uint32_t len; uint32_t tag, size; } h;
    if ([self shaderRead:at task:task to:&h length:sizeof h]) return nil;
    if (h.len > 32u * 1024u * 1024u) {
        [self complain:@"library exceeds the 32 MiB replay limit"];
        return nil;
    }
    NSMutableData *lib = [NSMutableData dataWithLength:h.len];
    if ([self shaderRead:h.off task:task to:lib.mutableBytes length:h.len]) return nil;
    __block NSError *err = nil;
    id<MTLLibrary> library = nil;
#if TARGET_OS_IPHONE
    __block NSString *libraryID = nil;
    NSString *convertedPath = nil;
    NSString *convertedRoute = nil;
    BOOL usedConverted = NO;
    __block NSDictionary *agxSelected = nil;
    __block NSDictionary *selectedProfileReceipt=nil;
    __block NSData *selectedProfileBytes=nil;
    __block NSString *selectedProfileRecipe=nil;
    const uint8_t *bytes = lib.bytes;
    BOOL macLibrary = lib.length >= 6 && !memcmp(bytes, "MTLB", 4) && bytes[4] == 1 && bytes[5] == 0x80;
    id (^loadConvertedLibrary)(NSData *, NSDictionary *, NSString *) = ^id(NSData *candidate, NSDictionary *receipt, NSString *recipe) {
        dispatch_data_t compiled = dispatch_data_create(candidate.bytes, candidate.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *loadError = nil;
        id loaded = [device newLibraryWithData:compiled error:&loadError];
        if (loaded) {
            agxSelected = hv_agx_library(candidate, libraryID, @"converted-candidate");
            selectedProfileReceipt=receipt;selectedProfileBytes=candidate;selectedProfileRecipe=recipe;
        }
        if (!loaded) err = loadError ?: err;
        return loaded;
    };
    if (macLibrary) {
        /* Prefer an existing recipe/hash-validated iOS conversion. This is a
           cache-only lookup: a cold macOS library does not start a new online
           conversion here. Preserve explicitly preferred legacy conversions. */
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes, (CC_LONG)lib.length, digest);
        char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
        for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
            snprintf(hex + i * 2, 3, "%02x", digest[i]);
        libraryID = [NSString stringWithUTF8String:hex];
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        convertedPath = [documents stringByAppendingPathComponent:
            [NSString stringWithFormat:@"sonoma-ioslib-%s.metallib", hex]];
        NSString *preferPath = [documents stringByAppendingPathComponent:
            [NSString stringWithFormat:@"sonoma-prefer-%s", hex]];
        /* Local conversion is enabled independently of any Mac compiler config.
           An old verified protocol3 cache remains an optional warm-first source. */
        if(activeCommand && !preflighting){
            activeCommand->error=@"A shader dependency was discovered after replay preflight; the uncommitted batch is retained.";
            return nil;
        }
        HGOnDeviceShaderResult *pinned=activeCommand->localResults[libraryID];
        if(pinned){
            library=loadConvertedLibrary(pinned.output,pinned.receipt,pinned.recipe);convertedRoute=pinned.route;
            if(!library){activeCommand->error=err.localizedDescription?:@"The retained shader could not be loaded.";return nil;}
        }else if(hv_shader_profile_required(documents))
            library=hv_shader_load_profiled(documents,libraryID,convertedPath,nil,
                [[NSFileManager defaultManager]fileExistsAtPath:preferPath],NO,loadConvertedLibrary,&convertedRoute);
        if(!library){
            HGOnDeviceShaderResult *result=[self requestLocalShader:lib sourceSHA:libraryID];
            if(activeCommand->error)return nil;
            if(result.status!=HGOnDeviceShaderReady){preflightWaiting=YES;return nil;}
            library=loadConvertedLibrary(result.output,result.receipt,result.recipe);
            convertedRoute=result.route;
            if(!library){activeCommand->error=err.localizedDescription?:@"The converted shader could not be loaded.";return nil;}
        }
        usedConverted = library != nil;
        if (!library) {
            /* Keep a source available even when a present legacy file is
               unusable; its existence must not block a later broker request. */
            NSString *capturePath = [documents stringByAppendingPathComponent:
                [NSString stringWithFormat:@"sonoma-guestlib-%s.metallib", hex]];
            if (![[NSFileManager defaultManager] fileExistsAtPath:capturePath])
                [lib writeToFile:capturePath atomically:YES];
        }
    }
#endif
    /* Preserve upstream's explicit native-Mac relabel diagnostic. Normal iOS
       loading still prefers validated conversions before metadata fallback. */
    const char *forcedRelabel = getenv("HV_PVG_RELABEL");
    int forcedRelabelStage = forcedRelabel && atoi(forcedRelabel) >= 1 && atoi(forcedRelabel) <= 3 ? atoi(forcedRelabel) : 0;
    int loaded_at = -1;
    BOOL forceNativeRelabel = NO;
#if !TARGET_OS_IPHONE
    forceNativeRelabel = forcedRelabelStage && !getenv("HV_PVG_NO_RELABEL");
#endif
    if (!library && !forceNativeRelabel) {
        dispatch_data_t data = dispatch_data_create(lib.bytes, lib.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        library = [device newLibraryWithData:data error:&err];
#if TARGET_OS_IPHONE
        if (library) agxSelected = hv_agx_library(lib, libraryID, @"original-library");
#endif
    }
#if TARGET_OS_IPHONE
    if (!library && macLibrary) {
        library = hv_shader_load_profiled(convertedPath.stringByDeletingLastPathComponent,
            libraryID, convertedPath, nil, YES, YES, loadConvertedLibrary, &convertedRoute);
        usedConverted = library != nil;
    }
    if (usedConverted)
        fprintf(stderr, "hengevm: shader-broker: selected %s source=%s recipe=%s before function creation\n",
                convertedRoute.UTF8String, libraryID.UTF8String, selectedProfileRecipe.UTF8String?:"unknown");
#endif
    if (!library && !getenv("HV_PVG_NO_RELABEL")) {
        int first = forcedRelabelStage ?: 2;
        int last = forcedRelabelStage == 3 ? 3 : 2;
        for (int stage = first; stage <= last && !library; stage++) {
            NSMutableData *candidate = [lib mutableCopy];
            const char *why = NULL;
            if (hv_metallib_relabel(candidate.mutableBytes, candidate.length, stage, &why) <= 0) continue;
            if (why) [self complain:[NSString stringWithFormat:@"library: relabel stage %d partial: %s", stage, why]];
            dispatch_data_t data = dispatch_data_create(candidate.bytes, candidate.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            NSError *retryError = nil;
            library = [device newLibraryWithData:data error:&retryError];
#if TARGET_OS_IPHONE
            if (library) agxSelected = hv_agx_library(candidate, libraryID, [NSString stringWithFormat:@"metadata-relabel-stage-%d", stage]);
#endif
            if (library) {
                loaded_at = stage;
                if (!getenv("HV_PVG_RELABEL_QUIET"))
                    [self complain:[NSString stringWithFormat:@"library: metadata relabel stage %d accepted; pipeline compatibility remains separate", stage]];
            } else err = retryError ?: err;
        }
    }
    if (!library) {
        [self complain:[NSString stringWithFormat:@"library: %@", err.localizedDescription]];
        return nil;
    }
    {   /* m4 fork: while tracing, keep each library macOS sends, to read its shaders on a Mac. Also, unless
           HV_SHADER_DUMP=0, the first 48 that had to be relabelled (Documents/shaders, as sent): what an OS that
           refuses them was sent, for relabelling to be checked against on a Mac. */
        static int relabelled_kept = 0;
        const char *tf = getenv("HV_PVG_TRACE_FILE"), *sd = getenv("HV_SHADER_DUMP");
        int keep = sd ? atoi(sd) != 0 : loaded_at > 0 && relabelled_kept < 48;
        if (keep && !sd) relabelled_kept++;
        if (tf && keep) {
            NSString *dir = [[[NSString stringWithUTF8String:tf] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shaders"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *name = [NSString stringWithFormat:@"%@-%llx.metallib", library.functionNames.firstObject ?: @"lib", (unsigned long long)at];
            [lib writeToFile:[dir stringByAppendingPathComponent:name] atomically:NO];
        }
    }
    id<MTLFunction> function = [library newFunctionWithName:library.functionNames.firstObject];
#if TARGET_OS_IPHONE
    if (function && selectedProfileReceipt && !hv_shader_profile_attach(function,selectedProfileReceipt,selectedProfileBytes,libraryID,selectedProfileRecipe)) {
        [self complain:@"profiled Metal function identity/type mismatch"];return nil;
    }
    if (agxSelected && usedConverted) {
        NSMutableDictionary *selection=[agxSelected mutableCopy];
        selection[@"route"]=convertedRoute ?: @"converted-candidate";agxSelected=selection;
    }
    hv_agx_bind(function, agxSelected);
    if (function && libraryID)
        objc_setAssociatedObject(function, "hvLibraryID",
                                 [NSString stringWithFormat:@"%@:%@", libraryID,
                                  usedConverted ? @"ios-air" : @"guest-library"],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    /* A macOS library may load successfully but be rejected only when Metal
       creates a pipeline. Keep its converted counterpart for that retry. */
    if (function && convertedPath && !usedConverted)
        objc_setAssociatedObject(function, "hvConvertedPath", convertedPath, OBJC_ASSOCIATION_COPY_NONATOMIC);
#endif
    return function;
}

#if TARGET_OS_IPHONE
- (id<MTLFunction>)convertedFunction:(id<MTLFunction>)original {
    NSString *path = original ? objc_getAssociatedObject(original, "hvConvertedPath") : nil;
    if (!path) return nil;
    NSString *identity = objc_getAssociatedObject(original, "hvLibraryID");
    NSString *digest = [identity componentsSeparatedByString:@":"].firstObject;
    NSString *route = nil;
    __block NSDictionary *agxSelected = nil;
    id<MTLFunction> function = hv_shader_load_profiled(path.stringByDeletingLastPathComponent,
        digest, path, original.name, YES, YES, ^id(NSData *bytes, NSDictionary *receipt, NSString *recipe) {
            dispatch_data_t data = dispatch_data_create(bytes.bytes, bytes.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            id<MTLLibrary> alternate = [device newLibraryWithData:data error:nil];
            id<MTLFunction> selected=[alternate newFunctionWithName:original.name];
            if(selected&&receipt&&!hv_shader_profile_attach(selected,receipt,bytes,digest,recipe))return nil;
            if (selected) agxSelected=hv_agx_library(bytes, digest, @"converted-retry");
            return selected;
        }, &route);
    if (function) {
        if (agxSelected) { NSMutableDictionary *selection=[agxSelected mutableCopy];
            selection[@"route"]=route ?: @"converted-retry";hv_agx_bind(function,selection); }
        if (digest) objc_setAssociatedObject(function, "hvLibraryID", [digest stringByAppendingString:@":ios-air"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        fprintf(stderr, "hengevm: shader-broker: selected %s source=%s function=%s for pipeline retry\n",
                route.UTF8String, digest.UTF8String, original.name.UTF8String);
    }
    return function;
}
#endif

- (id)makeSerialized:(uint64_t)at length:(uint32_t)size task:(uint32_t)task {
    if (size < sizeof(uint32_t)) return nil;
    NSMutableData *all = [NSMutableData dataWithLength:size];
    if ([self shaderRead:at task:task to:all.mutableBytes length:size]) return nil;
    const uint32_t *w = all.bytes;
    uint32_t tag = w[0];
    if ((tag == 0xe || tag == 0x33 || tag == 0xb) && (size < 16 || w[3] > size - 16)) {
        [self complain:@"serialized pipeline data exceeds its declared range"];
        return nil;
    }
    if (tag == 0xe || tag == 0x33) { /* render or tile pipeline: {tag, size, ref, length, data} */
        id<HvMetalSPI> spi = (id)device;
        HvContext *ctx = [HvContext new];
        ctx->replay = self, ctx->task = task;
#if TARGET_OS_IPHONE
        NSString *auditMarker = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"shader-audit-capture"];
        if ([NSFileManager.defaultManager fileExistsAtPath:auditMarker] || hv_agx_enabled()) ctx->auditFunctions = [NSMutableDictionary new];
#endif
#if TARGET_OS_IPHONE
        NSMutableDictionary *agxAttempt=hv_agx_begin(all,tag,task);
        hv_agx_phase(agxAttempt,nil,ctx->auditFunctions,@"before_deserialize",nil);
#endif
        dispatch_data_t data = dispatch_data_create((const uint8_t *)all.bytes + 16, w[3], NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        id descriptor = tag == 0xe ? [spi newRenderPipelineDescriptorWithSerializedData:data deserializationContext:ctx]
                                   : [spi newTileRenderPipelineDescriptorWithSerializedData:data deserializationContext:ctx];
        if (!descriptor || ctx->failure) {
#if TARGET_OS_IPHONE
            hv_agx_phase(agxAttempt,nil,ctx->auditFunctions,@"descriptor_failed",nil);
#endif
            [self complain:[NSString stringWithFormat:@"pipeline descriptor %u: %@", tag, ctx->failure]];
            return nil;
        }
        NSError *err = nil;
#if TARGET_OS_IPHONE
        capture_pipeline_attempt(all, ctx->auditFunctions, tag, task, @"entered_driver");
        hv_agx_phase(agxAttempt,descriptor,ctx->auditFunctions,@"first_entered_driver",nil);
#endif
        id state = tag == 0xe ? [device newRenderPipelineStateWithDescriptor:descriptor error:&err]
                              : [device newRenderPipelineStateWithTileDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&err];
#if TARGET_OS_IPHONE
        hv_agx_phase(agxAttempt,descriptor,ctx->auditFunctions,state?@"first_created":@"first_returned_error",err);
        if (!state && tag == 0xe) {
            MTLRenderPipelineDescriptor *rp = descriptor;
            id<MTLFunction> vertex = [self convertedFunction:rp.vertexFunction];
            id<MTLFunction> fragment = [self convertedFunction:rp.fragmentFunction];
            if (vertex || fragment) {
                if (vertex) rp.vertexFunction = vertex;
                if (fragment) rp.fragmentFunction = fragment;
                NSError *retryError = nil;
                hv_agx_phase(agxAttempt,rp,ctx->auditFunctions,@"retry_entered_driver",nil);
                state = [device newRenderPipelineStateWithDescriptor:rp error:&retryError];
                hv_agx_phase(agxAttempt,rp,ctx->auditFunctions,state?@"retry_created":@"retry_returned_error",retryError);
                if (state) fprintf(stderr, "hengevm: pvg-metal: retried pipeline %s with converted AIR\n",
                                   rp.fragmentFunction.name.UTF8String ?: "(no fragment)");
                else err = retryError ?: err;
            }
        }
        if (!state && tag == 0x33) {
            MTLTileRenderPipelineDescriptor *tp = descriptor;
            id<MTLFunction> alternate = [self convertedFunction:tp.tileFunction];
            if (alternate) {
                tp.tileFunction = alternate;
                NSError *retryError = nil;
                hv_agx_phase(agxAttempt,tp,ctx->auditFunctions,@"retry_entered_driver",nil);
                state = [device newRenderPipelineStateWithTileDescriptor:tp options:MTLPipelineOptionNone reflection:nil error:&retryError];
                hv_agx_phase(agxAttempt,tp,ctx->auditFunctions,state?@"retry_created":@"retry_returned_error",retryError);
                if (state) fprintf(stderr, "hengevm: pvg-metal: retried tile pipeline %s with converted AIR\n", tp.tileFunction.name.UTF8String);
                else err = retryError ?: err;
            }
        }
#endif
        if (!state) {
            NSString *functions = tag == 0xe ?
                [NSString stringWithFormat:@"%@ / %@", ((MTLRenderPipelineDescriptor *)descriptor).vertexFunction.name,
                 ((MTLRenderPipelineDescriptor *)descriptor).fragmentFunction.name] : @"tile";
            [self complain:[NSString stringWithFormat:@"pipeline %u (%@): %@", tag, functions, err.localizedDescription]];
#if TARGET_OS_IPHONE
            if (tag == 0xe) {
                MTLRenderPipelineDescriptor *rp = descriptor;
                NSString *vertexID = objc_getAssociatedObject(rp.vertexFunction, "hvLibraryID") ?: @"unknown";
                NSString *fragmentID = objc_getAssociatedObject(rp.fragmentFunction, "hvLibraryID") ?: @"unknown";
                fprintf(stderr, "hengevm: pvg-metal: rejected render state vertex=%s library=%s fragment=%s library=%s sample=%lu color0=%lu depth=%lu stencil=%lu error=%s\n",
                        rp.vertexFunction.name.UTF8String ?: "(nil)", vertexID.UTF8String,
                        rp.fragmentFunction.name.UTF8String ?: "(nil)", fragmentID.UTF8String,
                        (unsigned long)rp.rasterSampleCount, (unsigned long)rp.colorAttachments[0].pixelFormat,
                        (unsigned long)rp.depthAttachmentPixelFormat, (unsigned long)rp.stencilAttachmentPixelFormat,
                        err.localizedDescription.UTF8String ?: "(nil)");
                if (getenv("HV_SHADER_DUMP") && atoi(getenv("HV_SHADER_DUMP"))) {
                    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(all.bytes, (CC_LONG)all.length, digest);
                    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
                    for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
                        snprintf(hex + i * 2, 3, "%02x", digest[i]);
                    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                    NSString *path = [documents stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"sonoma-failed-pipeline-%s.bin", hex]];
                    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
                        [all writeToFile:path atomically:NO];
                    fprintf(stderr, "hengevm: pvg-metal: rejected pipeline data %s\n", path.UTF8String);
                }
            }
#endif
        }
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
#if TARGET_OS_IPHONE
        if (state && tag == 0xe) {
            /* descriptor contains the final selected functions, including
               converted retry replacements. Never infer this from a name. */
            MTLRenderPipelineDescriptor *rp = descriptor;
            hv_pvg_pipeline_set_gl_clip(state, hv_shader_function_gl_clip(rp.vertexFunction));
        }
#endif
        if (state && tag == 0xe && getenv("HV_PVG_TRACE_FILE")) {
            MTLRenderPipelineDescriptor *rp = descriptor;
            objc_setAssociatedObject(state, "hvname", [NSString stringWithFormat:@"%@ / %@ -> fmt %lu blend %d", rp.vertexFunction.name, rp.fragmentFunction.name, (unsigned long)rp.colorAttachments[0].pixelFormat, (int)rp.colorAttachments[0].blendingEnabled], OBJC_ASSOCIATION_RETAIN);
        }
#if TARGET_OS_IPHONE
        capture_pipeline_attempt(all, ctx->auditFunctions, tag, task, state ? @"created" : @"returned_error");
        capture_pipeline_descriptor(all, ctx->auditFunctions, tag, state != nil, err);
#endif
        return state;
    }
    if (tag == 0xb) { /* compute pipeline: {tag, size, ref, length, data} */
        id<HvMetalSPI> spi = (id)device;
        HvContext *ctx = [HvContext new];
        ctx->replay = self, ctx->task = task;
#if TARGET_OS_IPHONE
        NSString *auditMarker = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"shader-audit-capture"];
        if ([NSFileManager.defaultManager fileExistsAtPath:auditMarker] || hv_agx_enabled()) ctx->auditFunctions = [NSMutableDictionary new];
#endif
#if TARGET_OS_IPHONE
        NSMutableDictionary *agxAttempt=hv_agx_begin(all,tag,task);
        hv_agx_phase(agxAttempt,nil,ctx->auditFunctions,@"before_deserialize",nil);
#endif
        dispatch_data_t data = dispatch_data_create((const uint8_t *)all.bytes + 16, w[3], NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        ctx->standIn = [self computeStandIn];
        id descriptor = [spi newComputePipelineDescriptorWithSerializedData:data deserializationContext:ctx];
        if (!descriptor || ctx->failure) {
#if TARGET_OS_IPHONE
            hv_agx_phase(agxAttempt,nil,ctx->auditFunctions,@"descriptor_failed",nil);
#endif
            [self complain:[NSString stringWithFormat:@"compute descriptor: %@", ctx->failure]];
            return nil;
        }
        NSError *err = nil;
#if TARGET_OS_IPHONE
        capture_pipeline_attempt(all, ctx->auditFunctions, tag, task, @"entered_driver");
        hv_agx_phase(agxAttempt,descriptor,ctx->auditFunctions,@"first_entered_driver",nil);
#endif
        id state = [device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&err];
#if TARGET_OS_IPHONE
        hv_agx_phase(agxAttempt,descriptor,ctx->auditFunctions,state?@"first_created":@"first_returned_error",err);
        MTLComputePipelineDescriptor *cp = descriptor;
        if (!state) {
            id<MTLFunction> alternate = [self convertedFunction:cp.computeFunction];
            if (alternate) {
                cp.computeFunction = alternate;
                NSError *retryError = nil;
                hv_agx_phase(agxAttempt,cp,ctx->auditFunctions,@"retry_entered_driver",nil);
                state = [device newComputePipelineStateWithDescriptor:cp options:MTLPipelineOptionNone reflection:nil error:&retryError];
                hv_agx_phase(agxAttempt,cp,ctx->auditFunctions,state?@"retry_created":@"retry_returned_error",retryError);
                if (state) fprintf(stderr, "hengevm: pvg-metal: retried compute pipeline %s with converted AIR\n", cp.computeFunction.name.UTF8String);
                else err = retryError ?: err;
            }
        }
        capture_pipeline_attempt(all, ctx->auditFunctions, tag, task, state ? @"created" : @"returned_error");
        if (!state) fprintf(stderr, "hengevm: pvg-metal: rejected compute state function=%s library=%s error=%s\n",
                            cp.computeFunction.name.UTF8String ?: "unknown",
                            [objc_getAssociatedObject(cp.computeFunction, "hvLibraryID") UTF8String] ?: "unknown",
                            err.localizedDescription.UTF8String ?: "unknown");
#endif
        if (!state) [self complain:[NSString stringWithFormat:@"compute pipeline (%@): %@",
                                  ((MTLComputePipelineDescriptor *)descriptor).computeFunction.name,
                                  err.localizedDescription]];
        if (state) {
            id<MTLFunction> function = ((MTLComputePipelineDescriptor *)descriptor).computeFunction;
            NSString *identity = [NSString stringWithFormat:@"function=%@ library=%@", function.name,
                                  objc_getAssociatedObject(function, "hvLibraryID") ?: @"unknown"];
            objc_setAssociatedObject(state, "hvComputeIdentity", identity, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(state, "hvname", [NSString stringWithFormat:@"compute %@", function.name], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            fprintf(stderr, "hengevm: pvg-metal: compute created %s\n", identity.UTF8String);
        }
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
    HvOrdinaryTextureRecord texture;
    if (!hv_pvg_decode_ordinary_texture(all.bytes, all.length, &texture)) {
        [self complain:@"ordinary texture record exceeds its declared layout/descriptor bounds"];
        return;
    }
    o->length = texture.length;
    o->vpage = texture.page;
    o->tex_mips = texture.mips;
    o->tex_slices = texture.slices;
    o->tex_base = texture.base;
    o->tex_stride = texture.stride;
    o->tex_block_h = texture.block_height;
    size_t table = (size_t)texture.mips * 36;
    o->tex_layout = malloc(table);
    if (!o->tex_layout) { [self complain:@"ordinary texture layout allocation failed"]; return; }
    memcpy(o->tex_layout, texture.layout, table);
    MTLTextureDescriptor *t = texture.v2 ? descriptor_v2(texture.descriptor) : descriptor_v1(texture.descriptor);
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
        o->surface_plane = parent->surface_plane;
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

/* A multi-plane surface as a real IOSurface. First-form plane records start
   at +0x40 with 0x40-byte stride and packed dimensions; second-form records
   start at +0x80 with 0x80-byte stride and 64-bit dimensions. */
static IOSurfaceRef make_iosurface(HvObject *to, const uint8_t *desc, uint64_t alloc, BOOL legacy) {
    uint32_t fourcc, planes = desc[legacy ? 0x24 : 0x3e];
    if (planes < 2 || planes > 4) return NULL;
    uint64_t width, height;
    memcpy(&fourcc, desc + 4, 4);
    if (legacy) {
        uint32_t w, h;
        memcpy(&w, desc + 0x14, 4), memcpy(&h, desc + 0x18, 4);
        width = w >> 8, height = h >> 8;
    } else {
        memcpy(&width, desc + 0x20, 8), memcpy(&height, desc + 0x28, 8);
    }
    NSMutableArray *info = [NSMutableArray new], *plain = [NSMutableArray new];
    uint64_t at = 0;
    for (uint32_t i = 0; i < planes && i < 4; i++) {
        const uint8_t *pl = desc + (legacy ? 0x40 : 0x80) * (i + 1);
        uint64_t off, base, size, w, h, row;
        uint16_t bpe;
        if (legacy) {
            uint32_t o32, b32, s32, w32, h32, r32;
            memcpy(&o32, pl + 8, 4), memcpy(&b32, pl + 0xc, 4), memcpy(&s32, pl + 0x10, 4);
            memcpy(&w32, pl + 0x14, 4), memcpy(&h32, pl + 0x18, 4);
            memcpy(&r32, pl + 0x1c, 4), memcpy(&bpe, pl + 0x20, 2);
            off = o32, base = b32, size = s32, w = w32 >> 8, h = h32 >> 8, row = r32;
        } else {
            memcpy(&off, pl + 8, 8), memcpy(&base, pl + 0x10, 8), memcpy(&size, pl + 0x18, 8), memcpy(&w, pl + 0x20, 8), memcpy(&h, pl + 0x28, 8), memcpy(&row, pl + 0x30, 8), memcpy(&bpe, pl + 0x38, 2);
        }
        if (!w || !h || w > 8192 || h > 8192 || !bpe || bpe > 16 ||
            row < w * bpe || row > (1u << 20) || size < row * h ||
            base > alloc || size > alloc - base || off < base ||
            off - base > size || row * h > size - (off - base)) {
            fprintf(stderr, "hengevm: pvg-metal: invalid surface plane %u base %llu off %llu size %llu %llux%llu row %llu bpe %u alloc %llu\n",
                    i, base, off, size, w, h, row, bpe, alloc);
            return NULL;
        }
        [info addObject:@{(__bridge id)kIOSurfacePlaneWidth: @(w), (__bridge id)kIOSurfacePlaneHeight: @(h), (__bridge id)kIOSurfacePlaneBytesPerRow: @(row),
                          /* offset is the active image inside a padded plane;
                             size belongs to base, not to that active offset. */
                          (__bridge id)kIOSurfacePlaneOffset: @(off), (__bridge id)kIOSurfacePlaneSize: @(row * h), (__bridge id)kIOSurfacePlaneBytesPerElement: @(bpe),
                          (__bridge id)kIOSurfacePlaneElementWidth: @1, (__bridge id)kIOSurfacePlaneElementHeight: @1}];
        [plain addObject:@{(__bridge id)kIOSurfacePlaneWidth: @(w), (__bridge id)kIOSurfacePlaneHeight: @(h), (__bridge id)kIOSurfacePlaneBytesPerRow: @(row),
                           (__bridge id)kIOSurfacePlaneOffset: @(at), (__bridge id)kIOSurfacePlaneSize: @(row * h), (__bridge id)kIOSurfacePlaneBytesPerElement: @(bpe),
                           (__bridge id)kIOSurfacePlaneElementWidth: @1, (__bridge id)kIOSurfacePlaneElementHeight: @1}];
        to->plane_from[i] = off, to->plane_row[i] = row, to->plane_h[i] = h;
        to->plane_w[i] = w, to->plane_bpe[i] = bpe;
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

/* The guest can use 16-byte row alignment for small RGBA/BGRA surfaces.
   Give Metal its preferred stride while preserving the guest layout for copyback. */
static IOSurfaceRef make_packed_iosurface(HvObject *surface, id<MTLDevice> device,
                                        uint64_t width, uint64_t height, uint64_t alloc) {
    if (!surface->object || (surface->fourcc != 'RGBA' && surface->fourcc != 'BGRA')) return NULL;
    MTLPixelFormat format = surface->fourcc == 'RGBA' ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatBGRA8Unorm;
    NSUInteger alignment = [device minimumLinearTextureAlignmentForPixelFormat:format];
    if (!alignment || (surface->row % alignment == 0 && surface->first % alignment == 0)) return NULL;
    HvPvgSurfaceCopyback plan;
    if (!hv_pvg_surface_copyback_plan(surface->first, alloc, surface->length, 0,
                                     surface->row, width, height, 4, &plan)) return NULL;
    size_t hostRow = IOSurfaceAlignProperty(kIOSurfacePlaneBytesPerRow,
                                          (plan.active_row + alignment - 1) / alignment * alignment);
    NSDictionary *plane = @{(__bridge id)kIOSurfacePlaneWidth:@(width),
        (__bridge id)kIOSurfacePlaneHeight:@(height), (__bridge id)kIOSurfacePlaneBytesPerElement:@4,
        (__bridge id)kIOSurfacePlaneBytesPerRow:@(hostRow), (__bridge id)kIOSurfacePlaneOffset:@0,
        (__bridge id)kIOSurfacePlaneSize:@(hostRow * height)};
    NSDictionary *properties = @{(__bridge id)kIOSurfaceWidth:@(width),
        (__bridge id)kIOSurfaceHeight:@(height), (__bridge id)kIOSurfacePixelFormat:@(surface->fourcc),
        (__bridge id)kIOSurfacePlaneInfo:@[plane]};
    IOSurfaceRef made = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!made) return NULL;
    if (IOSurfaceGetPlaneCount(made) != 1 || IOSurfaceGetWidthOfPlane(made, 0) != width ||
        IOSurfaceGetHeightOfPlane(made, 0) != height || IOSurfaceGetBytesPerElementOfPlane(made, 0) != 4 ||
        IOSurfaceGetBytesPerRowOfPlane(made, 0) < plan.active_row) {
        CFRelease(made);
        return NULL;
    }
    surface->plane_count = 1;
    surface->plane_w[0] = width;
    surface->plane_h[0] = height;
    surface->plane_row[0] = surface->row;
    surface->plane_bpe[0] = 4;
    return made;
}

static HvObject *canonical_surface(HvObject *surface) {
    return surface && surface->surface_owner ? surface->surface_owner : surface;
}

static void release_planar_alias(NSMutableDictionary *planar, NSMutableDictionary *uses, HvObject *surface) {
    NSString *key = surface ? surface->planar_key : nil;
    if (!key) return;
    surface->planar_key = nil;
    if (planar[key] != canonical_surface(surface)) return;
    unsigned remaining = [uses[key] unsignedIntValue];
    if (remaining > 1) uses[key] = @(remaining - 1);
    else { [planar removeObjectForKey:key]; [uses removeObjectForKey:key]; }
}

/* Guest pixels into a copied IOSurface. Sampling bytes misses small updates,
   and comparing against the host surface would overwrite GPU-only changes.
   Compare all guest bytes against exactly what the last CPU upload contained. */
static void sync_iosurface(HvObject *s, id<MTLDevice> device) {
    s = canonical_surface(s);
    if (!s->iosurface) return;
    /* The replay worker may reach the next use before the preceding GPU write
       finishes. Its copyback changes guest bytes AND the shadow. Wait only for
       this surface, before inspecting either; no completion callback needs the
       worker. The weak slot does not retain completed buffers indefinitely. */
    id<MTLCommandBuffer> pending = s->surface_pending;
    if (pending) {
        [pending waitUntilCompleted];
        s->surface_pending = nil;
        if (pending.status != MTLCommandBufferStatusCompleted)
            s->surface_shadow_valid = NO;
    }
    const uint8_t *from = s->mapped + s->first;
    if (s->surface_shadow_valid && s->surface_shadow &&
        !memcmp(s->surface_shadow, from, s->alloc)) return;
    kern_return_t locked = IOSurfaceLock(s->iosurface, 0, NULL);
    if (locked != KERN_SUCCESS) {
        fprintf(stderr, "hengevm: pvg-metal: IOSurface CPU upload lock failed: %x\n", locked);
        return;
    }
    s->surface_shadow_valid = NO;
    if (!s->surface_shadow_buffer)
        s->surface_shadow_buffer = [device newBufferWithLength:s->alloc options:MTLResourceStorageModeShared];
    s->surface_shadow = s->surface_shadow_buffer.contents;
    if (s->surface_shadow) {
        memcpy(s->surface_shadow, from, s->alloc);
        from = s->surface_shadow;
    } /* Allocation failure loses only the skip optimization, never an update. */
    if (s->plane_count && IOSurfaceGetPlaneCount(s->iosurface) >= s->plane_count) {
        /* IOSurface can choose different offsets and row strides from those
           requested. Copy each video plane through its actual host layout. */
        for (uint32_t i = 0; i < s->plane_count && i < 4; i++) {
            uint8_t *dst = IOSurfaceGetBaseAddressOfPlane(s->iosurface, i);
            size_t dst_row = IOSurfaceGetBytesPerRowOfPlane(s->iosurface, i);
            size_t rows = MIN((size_t)s->plane_h[i], IOSurfaceGetHeightOfPlane(s->iosurface, i));
            uint64_t src_row = s->plane_row[i], src_off = s->plane_from[i];
            if (!dst || !src_row || src_off > s->alloc || rows > (s->alloc - src_off) / src_row) continue;
            size_t bytes = MIN((size_t)src_row, dst_row);
            for (size_t y = 0; y < rows; y++)
                memcpy(dst + y * dst_row, from + src_off + y * src_row, bytes);
        }
    } else {
        uint8_t *base = IOSurfaceGetBaseAddress(s->iosurface);
        memcpy(base, from, MIN(s->alloc, IOSurfaceGetAllocSize(s->iosurface)));
    }
    kern_return_t unlocked = IOSurfaceUnlock(s->iosurface, 0, NULL);
    s->surface_shadow_valid = s->surface_shadow && unlocked == KERN_SUCCESS;
    if (unlocked != KERN_SUCCESS)
        fprintf(stderr, "hengevm: pvg-metal: IOSurface CPU upload unlock failed: %x\n", unlocked);
    const char *dump = getenv("HV_PVG_SURFACE_DUMP");
    static int dumped;
    if (dump && s->plane_count && dumped < 6) {
        char path[1100];
        snprintf(path, sizeof path, "%s-%d.bin", dump, dumped++);
        FILE *f = fopen(path, "wb");
        if (f) fwrite(from, 1, s->alloc, f), fclose(f);
    }
}

/* A surface (IOSurface in the guest): a texture over its guest pages, so the
   guest's CPU and the GPU see the same pixels, as they do through a real one.
   {mapping id, tag, size, ref, description}. Its descriptor: page list at +0
   (physical >> 12, bit 0 present, one per 16 KB), first-page offset +0x60,
   allocation +0x18, bytes per row +0x30. */
- (void)makePrivateMappedTexture:(HvObject *)o descriptor:(MTLTextureDescriptor *)t mapping:(uint64_t)mapping {
    if (!t || !t.width || !t.height || t.width > 8192 || t.height > 8192) return;
    NSNumber *key = @(mapping);
    id<MTLTexture> existing = fallback_textures[key];
    if (existing && existing.width == t.width && existing.height == t.height &&
        existing.pixelFormat == t.pixelFormat) {
        o->object = existing;
        if (getenv("HV_PVG_TRACE_FILE"))
            fprintf(stderr, "hengevm: pvg-metal: fallback reuse map %llu %lux%lu fmt %lu tex %p\n",
                    (unsigned long long)mapping, (unsigned long)t.width, (unsigned long)t.height,
                    (unsigned long)t.pixelFormat, (__bridge void *)existing);
        return;
    }
    t.storageMode = MTLStorageModePrivate;
    t.usage |= MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    set_framebuffer_only(t, NO);
    t.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
                                              MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    o->object = [device newTextureWithDescriptor:t];
    if (!o->object) return;
    /* The guest sometimes leaves a mapped target partly unwritten with a
       DontCare load. A private fallback has no guest pages to supply the
       untouched pixels; iOS Metal may expose magenta allocator contents.
       Start color targets at transparent black before any guest command uses
       them, as a newly mapped zeroed surface would. */
    switch (t.pixelFormat) {
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatRGBA16Float: {
        MTLRenderPassDescriptor *clear = [MTLRenderPassDescriptor renderPassDescriptor];
        clear.colorAttachments[0].texture = o->object;
        clear.colorAttachments[0].loadAction = MTLLoadActionClear;
        clear.colorAttachments[0].storeAction = MTLStoreActionStore;
        BOOL tint = getenv("HV_PVG_FALLBACK_TINT") && t.width < 800 && t.height < 600;
        clear.colorAttachments[0].clearColor = tint ? MTLClearColorMake(1, 0, 1, 1)
                                                   : MTLClearColorMake(0, 0, 0, 0);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:clear];
        [encoder endEncoding];
        lifecycle_commit(self, cb, YES);
        break;
    }
    default: break;
    }
#if TARGET_OS_IPHONE
    /* A new private scanout has no guest pages containing pixels outside the
       first dirty rectangle. Seed it from the last displayed scanout once,
       before the guest's partial render passes begin. */
    if (t.width >= 800 && t.height >= 600 && t.sampleCount == 1) {
        id<MTLTexture> previous = last_fallback_scanout;
        if (previous && previous != o->object && previous.width == t.width &&
            previous.height == t.height && previous.pixelFormat == t.pixelFormat &&
            previous.sampleCount == 1) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:previous sourceSlice:0 sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(t.width, t.height, 1)
                       toTexture:o->object destinationSlice:0 destinationLevel:0
               destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
            lifecycle_commit(self, cb, YES);
            fprintf(stderr, "hengevm: pvg-metal: seeded scanout map %llu from displayed texture\n",
                    (unsigned long long)mapping);
        }
    }
#endif
    /* Mapping loss must remain visible even without verbose command tracing. */
    fprintf(stderr, "hengevm: pvg-metal: fallback create map %llu %lux%lu fmt %lu tex %p\n",
            (unsigned long long)mapping, (unsigned long)t.width, (unsigned long)t.height,
            (unsigned long)t.pixelFormat, (__bridge void *)o->object);
    id<MTLTexture> old = fallback_textures[key];
    if (!old || t.width * t.height >= old.width * old.height)
        fallback_textures[key] = o->object;
}

/* Diagnostic only: sample the actual host YUV texture independently of guest shaders. */
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
    BOOL compact = hv_pvg_lite_compact_surfaces(lite) != 0;
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
        alloc = a32, row = r32;
        memcpy(&first, desc + 8, 4);
    }
    if (!alloc || alloc > (512u << 20) || first >= 0x4000 || !row || row > (1u << 20)) {
        [self complain:[NSString stringWithFormat:@"surface %llu: invalid allocation/offset/row", mapping]];
        return nil;
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
    vm_address_t base = 0;
    uint32_t *decodedPages = compact && n <= 32768 ? calloc(n, sizeof(uint32_t)) : NULL;
    const uint32_t *pages = compact ?
        (decodedPages && hv_pvg_surface_pages(list, n, decodedPages, lite, surface_read_physical) ? decodedPages : NULL) :
        (list & 1) ? hv_pvg_lite_phys(lite, (uint64_t)(list & ~1u) << 12, n * 4) : NULL;
    if (!pages || vm_allocate(mach_task_self(), &base, surface->length, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        free(decodedPages);
        [self complain:[NSString stringWithFormat:@"surface %llu has no pages", mapping]];
        return nil;
    }
    surface->mapped = (uint8_t *)base;
    for (uint64_t i = 0; i < n; i++) {
        if (!(pages[i] & 1)) continue;
        uint8_t *src = hv_pvg_lite_phys(lite, (uint64_t)(pages[i] & ~3u) << 12, 0x4000);
        vm_address_t to = base + (i << 14);
        vm_prot_t cur, max;
        kern_return_t kr = src ? vm_remap(mach_task_self(), &to, 0x4000, 0, VM_FLAGS_OVERWRITE,
            mach_task_self(), (vm_address_t)src, FALSE, &cur, &max, VM_INHERIT_NONE) : KERN_INVALID_ADDRESS;
        if (kr != KERN_SUCCESS) { free(decodedPages); return nil; }
    }
    surface->object = [device newBufferWithBytesNoCopy:surface->mapped length:surface->length options:MTLResourceStorageModeShared
                                           deallocator:^(void *at, NSUInteger size) { vm_deallocate(mach_task_self(), (vm_address_t)at, size); }];
    surface->mapping_in_buffer = surface->object != nil;
    surfaces[key] = surface;
    IOSurfaceRef made = planes >= 2 ? make_iosurface(surface, desc, alloc, compact)
                                    : make_packed_iosurface(surface, device, sw, sh, alloc);
    if (made) {
        surface->alloc = alloc;
        /* The same guest memory, format and size under another mapping id (another process): the same host
           IOSurface, or what that process drew is not what this one sees. Its pixels are already there (or
           drawn over since), so they are not copied again now. */
        unsigned char pageDigest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_CTX identity;
        CC_SHA256_Init(&identity);
        for (uint64_t i = 0; i < n; i++) {
            uint32_t physical = pages[i] & ~3u;
            CC_SHA256_Update(&identity, &physical, sizeof physical);
        }
        CC_SHA256_Update(&identity, surface->plane_from, sizeof surface->plane_from);
        CC_SHA256_Update(&identity, surface->plane_row, sizeof surface->plane_row);
        CC_SHA256_Update(&identity, surface->plane_h, sizeof surface->plane_h);
        CC_SHA256_Update(&identity, surface->plane_w, sizeof surface->plane_w);
        CC_SHA256_Update(&identity, surface->plane_bpe, sizeof surface->plane_bpe);
        CC_SHA256_Final(pageDigest, &identity);
        NSMutableString *pageID = [NSMutableString new];
        for (unsigned i = 0; i < sizeof(pageDigest); i++) [pageID appendFormat:@"%02x", pageDigest[i]];
        NSString *pk = [NSString stringWithFormat:@"%@/%08x/%llux%llu/%llu/%u/%llu", pageID, surface->fourcc,
                        sw, sh, alloc, first, row];
        HvObject *shared = planar[pk];
        if (shared) {
            CFRelease(made);
            surface->surface_owner = shared;
            surface->iosurface = (IOSurfaceRef)CFRetain(shared->iosurface);
            surface->planar_key = pk;
            planar_uses[pk] = @(planar_uses[pk].unsignedIntValue + 1);
        } else {
            surface->iosurface = made;
            if (planar.count >= 512) [planar removeAllObjects], [planar_uses removeAllObjects];
            planar[pk] = surface;
            planar_uses[pk] = @1;
            surface->planar_key = pk;
        }
        sync_iosurface(surface, device);
    }
    free(decodedPages);
    fprintf(stderr, "hengevm: pvg-metal: surface %llu: %llux%llu, row %llu, %llu KB, fourcc %c%c%c%c planes %u\n", mapping, (unsigned long long)sw, (unsigned long long)sh, row, alloc >> 10, desc[7], desc[6], desc[5], desc[4], planes);
        return surface;
}

/* The surface under a mapping id as the guest describes it now. macOS 14's driver reuses ids for new surfaces
   without saying the old one went: a different description under the same id is a new surface (a 1920x48 BGRA
   strip, then the 1920x1080 half-float screen). */
- (HvObject *)currentSurface:(uint64_t)mapping {
    HvObject *surface = surfaces[@(mapping)];
    if (surface && hv_pvg_lite_compact_surfaces(lite)) {
        const uint8_t *now = hv_pvg_lite_surface(lite, (uint32_t)mapping);
        if (now && (now[0] | now[0x10]) && memcmp(surface->described, now, sizeof surface->described)) {
            release_planar_alias(planar, planar_uses, surface);
            [surfaces removeObjectForKey:@(mapping)];
            [mapped_textures removeObjectForKey:@(mapping)];
            surface = nil;
        }
    }
    return surface ? surface : [self newSurface:mapping];
}

static void probe_yuv_texture(HvReplay *replay, id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLTexture> texture) {
    static unsigned probes;
    if (!getenv("HV_PVG_YUV_PROBE") || !texture || probes++ >= 4) return;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void henge_sample(texture2d<float, access::sample> src [[texture(0)]], device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {"
        "constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);"
        "float2 p[4]={float2(.125,.125),float2(.5,.25),float2(.5,.5),float2(.75,.75)};"
        "out[i]=src.sample(s,p[i]);}";
    NSError *error = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> state = lib ? [device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"henge_sample"] error:&error] : nil;
    if (!state) { fprintf(stderr, "yuv-probe compile: %s\n", error.localizedDescription.UTF8String); return; }
    id<MTLBuffer> values = [device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:state]; [e setTexture:texture atIndex:0]; [e setBuffer:values offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(4,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
    [e endEncoding]; if (!lifecycle_commit(replay, cb, YES)) return; [cb waitUntilCompleted];
    const float *v = values.contents;
    fprintf(stderr, "yuv-probe fmt %lu status %lu error %s samples:", (unsigned long)texture.pixelFormat, (unsigned long)cb.status, cb.error.localizedDescription.UTF8String ?: "none");
    for (unsigned i = 0; i < 16; i++) fprintf(stderr, " %.4f", v[i]);
    fputc('\n', stderr);
}

- (void)makeMappedTexture:(HvObject *)o at:(uint64_t)at size:(uint32_t)recordSize task:(uint32_t)task {
    /* Keep the complete descriptor, including its trailing IOSurface plane.
       Its size includes the 12-byte Metal header, not just the d payload. */
    struct __attribute__((packed)) { uint64_t mapping; uint32_t tag, size, ref; uint8_t d[64]; } h;
    memset(&h, 0, sizeof h);
    uint32_t bytesRead = MIN(recordSize, (uint32_t)sizeof h);
    if (hv_pvg_lite_task_read(lite, task, at, &h, bytesRead)) return;
    HvMappedTextureRecord decoded;
    if (!hv_pvg_decode_mapped_texture((const uint8_t *)&h, bytesRead, &decoded)) {
        [self complain:[NSString stringWithFormat:@"mapped texture: invalid record size %u tag %u descriptor size %u", recordSize, h.tag, h.size]];
        return;
    }
    NSUInteger plane = decoded.plane;
    o->mapped_id = h.mapping;
    o->on_mapping = h.mapping;
    NSNumber *key = @(h.mapping);
    HvObject *surface = canonical_surface([self currentSurface:h.mapping]);
    if (hv_pvg_trace_on()) {
        fprintf(stderr, "trace: mapped texture ref %u tag %#x size %u mapping %llu:", h.ref, h.tag, h.size, h.mapping);
        for (int i = 0; i < 64; i += 4) fprintf(stderr, " %08x", *(uint32_t *)(h.d + i));
        fprintf(stderr, "\n");
    }
    MTLTextureDescriptor *t = h.tag == 0x39 ? descriptor_v2(h.d) : descriptor_v1(h.d);
    if (!surface) { [self makePrivateMappedTexture:o descriptor:t mapping:h.mapping]; return; }
    t.storageMode = MTLStorageModeShared;
    set_framebuffer_only(t, NO);
    t.usage |= MTLTextureUsageShaderRead;
    if (surface->iosurface && surface->plane_count > 1) t.usage &= ~MTLTextureUsageRenderTarget;
    else t.usage |= MTLTextureUsageRenderTarget;
    /* Metal aborts on a swizzled render target, and a surface is always drawn into here: views over it
       (tags 7/8/0x1b) can still swizzle. */
    MTLTextureSwizzleChannels sw = t.swizzle;
    if (sw.red != MTLTextureSwizzleRed || sw.green != MTLTextureSwizzleGreen || sw.blue != MTLTextureSwizzleBlue || sw.alpha != MTLTextureSwizzleAlpha) {
        static int told;
        if (told++ < 3) fprintf(stderr, "hengevm: pvg-metal: surface %llu asked for swizzle %u %u %u %u; drawing it unswizzled\n", h.mapping, sw.red, sw.green, sw.blue, sw.alpha);
        t.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    }
    o->surface = surface;
    o->surface_plane = (uint32_t)plane;
    /* Opt-in evidence for the mapped-record plane contract. */
    if (surface->iosurface && surface->plane_count > 1) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        static NSUInteger planeAuditCount;
        if (planeAuditCount < 128 && [[NSFileManager defaultManager] fileExistsAtPath:[docs stringByAppendingPathComponent:@"plane-audit"]]) {
            NSUInteger ordinal = planeAuditCount++;
            NSMutableData *payload = [NSMutableData dataWithLength:MIN(recordSize, 256u)];
            if (payload.length && !hv_pvg_lite_task_read(lite, task, at, payload.mutableBytes, payload.length)) {
                NSMutableArray *planes = [NSMutableArray new];
                for (NSUInteger i = 0; i < IOSurfaceGetPlaneCount(surface->iosurface); i++)
                    [planes addObject:@{@"plane":@(i), @"width":@(IOSurfaceGetWidthOfPlane(surface->iosurface,i)),
                        @"height":@(IOSurfaceGetHeightOfPlane(surface->iosurface,i)),
                        @"row":@(IOSurfaceGetBytesPerRowOfPlane(surface->iosurface,i)),
                        @"bytes_per_element":@(IOSurfaceGetBytesPerElementOfPlane(surface->iosurface,i))}];
                NSDictionary *entry = @{@"schema":@1, @"task":@(task), @"ref":@(h.ref), @"mapping":@(h.mapping),
                    @"record_size":@(recordSize), @"descriptor_tag":@(h.tag), @"descriptor_size":@(h.size),
                    @"payload_base64":[payload base64EncodedStringWithOptions:0],
                    @"width":@(t.width), @"height":@(t.height), @"pixel_format":@(t.pixelFormat),
                    @"fourcc":@(surface->fourcc), @"selected_plane":@(plane), @"planes":planes};
                NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingPrettyPrinted error:nil];
                NSString *path = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"plane-audit-%03lu.json",(unsigned long)ordinal]];
                [json writeToFile:path atomically:YES];
            }
        }
    }
    if (surface->iosurface) {
        if (plane >= IOSurfaceGetPlaneCount(surface->iosurface) ||
            t.width > IOSurfaceGetWidthOfPlane(surface->iosurface, plane) ||
            t.height > IOSurfaceGetHeightOfPlane(surface->iosurface, plane)) {
            [self complain:[NSString stringWithFormat:@"surface %llu: invalid plane %lu for view %lux%lu", h.mapping, (unsigned long)plane, (unsigned long)t.width, (unsigned long)t.height]];
            return;
        }
        if (surface->plane_count == 1 &&
            (t.textureType != MTLTextureType2D || t.mipmapLevelCount != 1 || t.sampleCount != 1 ||
             t.arrayLength != 1 || (t.pixelFormat != MTLPixelFormatRGBA8Unorm &&
             t.pixelFormat != MTLPixelFormatRGBA8Unorm_sRGB && t.pixelFormat != MTLPixelFormatBGRA8Unorm &&
             t.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB))) {
            [self complain:[NSString stringWithFormat:@"surface %llu: incompatible packed RGB view", h.mapping]];
            return;
        }
        o->object = [device newTextureWithDescriptor:t iosurface:surface->iosurface plane:plane];
        if (!o->object) { /* video formats cannot be drawn into */
            t.usage = MTLTextureUsageShaderRead;
            o->object = [device newTextureWithDescriptor:t iosurface:surface->iosurface plane:plane];
        }
        if (o->object && plane < 4 && !surface->plane_textures[plane]) {
            /* A guest view can cover less than the whole plane. Copyback uses
               a separate full-plane view so aliases cannot truncate it. */
            MTLTextureDescriptor *full = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat
                width:IOSurfaceGetWidthOfPlane(surface->iosurface, plane)
                height:IOSurfaceGetHeightOfPlane(surface->iosurface, plane) mipmapped:NO];
            full.storageMode = MTLStorageModeShared;
            full.usage = MTLTextureUsageShaderRead;
            surface->plane_textures[plane] = [device newTextureWithDescriptor:full iosurface:surface->iosurface plane:plane];
        }
    }
    else {
        if (plane) { [self complain:[NSString stringWithFormat:@"surface %llu: plane %lu on a non-planar mapping", h.mapping, (unsigned long)plane]]; return; }
        if (linear_texture_fits(device, t, surface->first, surface->row, ((id<MTLBuffer>)surface->object).length))
            o->object = [(id<MTLBuffer>)surface->object newTextureWithDescriptor:t offset:surface->first bytesPerRow:surface->row];
    }
    if (!o->object) {
        [self complain:[NSString stringWithFormat:@"surface %llu: format %lu row %llu not possible", h.mapping, (unsigned long)t.pixelFormat, surface->row]];
        t.storageMode = MTLStorageModePrivate;
        o->object = [device newTextureWithDescriptor:t]; /* something to bind: it stays empty */
        if (o->object) {
            fprintf(stderr, "hengevm: pvg-metal: fallback create map %llu %lux%lu fmt %lu tex %p after mapped texture failure\n",
                    h.mapping, (unsigned long)t.width, (unsigned long)t.height,
                    (unsigned long)t.pixelFormat, (__bridge void *)o->object);
            id<MTLTexture> old = fallback_textures[key];
            if (!old || t.width * t.height >= old.width * old.height)
                fallback_textures[key] = o->object;
        }
    } else {
        [fallback_textures removeObjectForKey:key];
    }
    if (surface->iosurface && surface->plane_count > 1) probe_yuv_texture(self, device, queue, o->object);
    if (!plane) mapped_textures[key] = o->object;
}

- (HvObject *)object:(uint32_t)ref task:(uint32_t)task {
    if (!ref || task >= 512) return nil;
    task_cache_generation(tasks, task_generations, task, hv_pvg_lite_task_generation(lite, task));
    uint64_t list = hv_pvg_lite_task_objects(lite, task);
    uint32_t e[3];
    if (!list || [self shaderRead:list + (uint64_t)ref * 12 task:task to:e length:12]) return nil;
    if(preflighting && (e[0]&0xff)!=OBJ_FUNCTION && (e[0]&0xff)!=OBJ_SERIALIZED) { activeCommand->error=@"non-function dependency in shader preflight"; return nil; }
    NSMutableDictionary *objs = tasks[@(task)];
    if (!objs) tasks[@(task)] = objs = [NSMutableDictionary new];
    HvObject *o = objs[@(ref)];
    if (o && !memcmp(o->entry, e, 12)) {
        /* macOS 14's driver names a surface before it writes the surface's description: try again a while.
           And it reuses surface ids: a texture over a surface that has since been replaced is made again. */
        BOOL replaced = o->object && (e[0] & 0xff) == OBJ_MAPPED_TEXTURE && hv_pvg_lite_compact_surfaces(lite) &&
                        o->surface != canonical_surface([self currentSurface:o->on_mapping]);
        if (replaced) o->retries = 0;
        if ((!o->object || replaced) && (e[0] & 0xff) == OBJ_MAPPED_TEXTURE && o->retries < 600) {
            uint32_t tries = o->retries + 1;
            o = nil;
            HvObject *again = [HvObject new];
            memcpy(again->entry, e, 12);
            again->retries = tries;
            objs[@(ref)] = again;
            uint64_t at = (uint64_t)e[2] << 32 | e[1];
            [self makeMappedTexture:again at:at size:e[0] >> 8 task:task];
            static int told;
            if (again->object && told++ < 30) fprintf(stderr, "hengevm: pvg-metal: task %u ref %u: texture made on try %u%s\n", task, ref, tries, replaced ? " (surface replaced)" : "");
            return again;
        }
        if (!o->follows) return o;
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
    case OBJ_MAPPED_TEXTURE: [self makeMappedTexture:o at:at size:size task:task]; break;
    default: {
        uint32_t w[24] = {0};
        hv_pvg_lite_task_read(lite, task, at, w, sizeof w);
        NSMutableString *m = [NSMutableString stringWithFormat:@"object type %u size %u:", type, size];
        for (int i = 0; i < 24; i++) [m appendFormat:@" %08x", w[i]];
        [self complain:m];
        break;
    }
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
- (void)page:(HvObject *)o toGuest:(BOOL)down task:(uint32_t)task blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb {
    id<MTLBuffer> copy = guest_copy(self, task, o);
    if (!copy || !has_guest_pages(o)) return;
    if (o->heap_whole) {
        if (!*blit) *blit = [cb blitCommandEncoder];
        NSUInteger bytes = MIN(copy.length, o->heap_whole.length);
        if (down) [*blit copyFromBuffer:o->heap_whole sourceOffset:0 toBuffer:copy destinationOffset:0 size:bytes];
        else [*blit copyFromBuffer:copy sourceOffset:0 toBuffer:o->heap_whole destinationOffset:0 size:bytes];
        return;
    }
    id<MTLTexture> tex = o->object;
    if (!tex || !o->tex_layout || tex.sampleCount > 1 || tex.isFramebufferOnly) return;
    NSUInteger faces = tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray ? 6 : 1;
    if (!*blit) *blit = [cb blitCommandEncoder];
    for (uint32_t s = 0; s < o->tex_slices * faces; s++)
        for (uint32_t m = 0; m < o->tex_mips; m++) {
            const uint8_t *mip = o->tex_layout + m * 36;
            uint64_t off, row;
            uint32_t w, h, d;
            memcpy(&off, mip, 8), memcpy(&row, mip + 0x10, 8), memcpy(&w, mip + 0x18, 4), memcpy(&h, mip + 0x1c, 4), memcpy(&d, mip + 0x20, 4);
            uint32_t bh = o->tex_block_h ? o->tex_block_h : 1;
            uint64_t from = o->tex_base + o->tex_stride * s + off;
            uint64_t image = row * ((h + bh - 1) / bh);
            if (from + image * d > o->length) continue;
            if (down)
                [*blit copyFromTexture:tex sourceSlice:s sourceLevel:m sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, d)
                              toBuffer:copy destinationOffset:from destinationBytesPerRow:row destinationBytesPerImage:image];
            else
                [*blit copyFromBuffer:copy sourceOffset:from sourceBytesPerRow:row sourceBytesPerImage:image
                           sourceSize:MTLSizeMake(w, h, d) toTexture:tex destinationSlice:s destinationLevel:m destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
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
        [self page:o toGuest:YES task:task blit:&blit commandBuffer:cb];
        o->guest_stale = NO;
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
    if (!viewport_replay) viewport_replay = [HvPvgViewportReplay new];
    hv_pvg_viewport_reset(viewport_replay);
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
                if (list) [self shaderRead:list + (uint64_t)ref * 12 task:task to:e length:12];
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
        if (c0 && c0.width >= 800 && c0.height >= 600 &&
            (c0.pixelFormat == MTLPixelFormatRGBA16Float ||
             c0.pixelFormat == MTLPixelFormatBGRA8Unorm ||
             c0.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB) && probe_targets)
            probe_targets[@(U32(0x4c))] = c0;
        fprintf(stderr, "trace: pass c0 ref %u tex %p %lux%lu fmt %lu load %lu store %lu clear %.2f %.2f %.2f %.2f surface %s heap %d\n", U32(0x4c), (__bridge void *)c0, (unsigned long)c0.width, (unsigned long)c0.height, (unsigned long)c0.pixelFormat, (unsigned long)d.colorAttachments[0].loadAction, (unsigned long)d.colorAttachments[0].storeAction, cc.red, cc.green, cc.blue, cc.alpha, co && co->surface ? "yes" : "no", c0.heap != nil);
    }
#if TARGET_OS_IPHONE
    /* Sonoma alternates private scanouts and often draws only a dirty
       rectangle. The guest's untouched pixels are not available through a
       private fallback. Bring the previous complete scanout across before
       the first render pass for the next one, then let the guest draw. */
    id<MTLTexture> target = d.colorAttachments[0].texture;
    if (target && target != seeded_target_since_present &&
        d.colorAttachments[0].loadAction == MTLLoadActionLoad) {
        BOOL known_scanout = NO;
        for (NSNumber *mapping in scanout_mappings) {
            if (fallback_textures[mapping] == target) { known_scanout = YES; break; }
        }
        if (known_scanout) {
            seeded_target_since_present = target;
            id<MTLTexture> previous = last_fallback_scanout;
            if (previous && previous != target && previous.width == target.width &&
                previous.height == target.height && previous.pixelFormat == target.pixelFormat &&
                previous.sampleCount == 1 && target.sampleCount == 1) {
                id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                [blit copyFromTexture:previous sourceSlice:0 sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(target.width, target.height, 1)
                           toTexture:target destinationSlice:0 destinationLevel:0
                   destinationOrigin:MTLOriginMake(0, 0, 0)];
                [blit endEncoding];
                static uint32_t copied;
                if (++copied <= 12 || copied % 200 == 0)
                    fprintf(stderr, "hengevm: pvg-metal: seeded dirty scanout %u from previous frame\n", copied);
            }
        }
    }
#endif
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:d];
    if (!e) {
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
        if (!hv_pvg_apply_store_action(e, tag, r.p, r.size))
            fprintf(stderr, "hengevm: pvg-metal: invalid store action tag %u (%u bytes)\n", tag, r.size);
        else if (tracing) fprintf(stderr, "trace:  finalized store action tag %u\n", tag);
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
        if (state) [e setRenderPipelineState:state];
        hv_pvg_viewport_pipeline(viewport_replay, e, state);
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
        if (tag == 125) [e setVertexBuffers:buffers offsets:offsets withRange:range];
        else if (tag == 110) [e setFragmentBuffers:buffers offsets:offsets withRange:range];
        else [e setTileBuffers:buffers offsets:offsets withRange:range];
        break;
    }
    case 126: [e setVertexBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)]; break;
    case 111: [e setFragmentBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)]; break;
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
            fprintf(stderr, "trace:  tex %u ref %u ptr %p %lux%lu fmt %lu type %u swz %d%d%d%d surface %s heap %d valid %d\n", index + i, U32(8 + i * 4), (__bridge void *)x, (unsigned long)x.width, (unsigned long)x.height, (unsigned long)x.pixelFormat, xo ? xo->entry[0] & 0xff : 0, x.swizzle.red, x.swizzle.green, x.swizzle.blue, x.swizzle.alpha, xo && xo->surface ? "yes" : "no", x.heap != nil, xo ? xo->host_valid : 0);
        }
        if (tag == 114) [e setFragmentTextures:items withRange:NSMakeRange(index, count)];
        else [e setTileTextures:items withRange:NSMakeRange(index, count)];
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
        [e setFragmentSamplerStates:items withRange:NSMakeRange(index, count)];
        break;
    }
    case 117: {
        MTLScissorRect s;
        memcpy(&s, r.p, sizeof s);
        [e setScissorRect:s];
        if (tracing) fprintf(stderr, "trace:  scissor %lu %lu %lu %lu\n", (unsigned long)s.x, (unsigned long)s.y, (unsigned long)s.width, (unsigned long)s.height);
        break;
    }
    case 130: {
        if (r.size >= sizeof(MTLViewport))
            hv_pvg_viewport_record(viewport_replay, e, r.p, 1, NO);
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
        [e setDepthStencilState:state];
        break;
    }
    case 107: [e setCullMode:(MTLCullMode)U32(0)]; break;
    case 108: {
        float f[3];
        memcpy(f, r.p, sizeof f);
        [e setDepthBias:f[0] slopeScale:f[1] clamp:f[2]];
        break;
    }
    case 109: [e setDepthClipMode:(MTLDepthClipMode)U32(0)]; break;
    case 115: [e setFrontFacingWinding:(MTLWinding)U32(0)]; break;
    case 124: [e setTriangleFillMode:(MTLTriangleFillMode)U32(0)]; break;
    case 119: [e setStencilFrontReferenceValue:U32(0) backReferenceValue:U32(4)]; break;
    case 118: { /* a header, then the rectangles */
        uint32_t head = r.size % sizeof(MTLScissorRect), n = (r.size - head) / sizeof(MTLScissorRect);
        if (n) [e setScissorRects:(const MTLScissorRect *)(r.p + head) count:n];
        break;
    }
    case 131: {
        uint32_t head = r.size % sizeof(MTLViewport), n = (r.size - head) / sizeof(MTLViewport);
        if (n) hv_pvg_viewport_record(viewport_replay, e, r.p + head, n, YES);
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
        [e setVertexTextures:items withRange:NSMakeRange(index, count)];
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
        [e setVertexSamplerStates:items withRange:NSMakeRange(index, count)];
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
        if (tag == 113) [e setFragmentSamplerStates:items lodMinClamps:lo lodMaxClamps:hi withRange:NSMakeRange(index, count)];
        else [e setVertexSamplerStates:items lodMinClamps:lo lodMaxClamps:hi withRange:NSMakeRange(index, count)];
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
        [e setVertexBuffers:buffers offsets:offsets attributeStrides:strides withRange:NSMakeRange(index, count)];
        break;
    }
    case 166: [e setVertexBufferOffset:(NSUInteger)U64(4) attributeStride:(NSUInteger)U64(12) atIndex:U32(0)]; break;
    case 101: {
        float c[4];
        memcpy(c, r.p, sizeof c);
        [e setBlendColorRed:c[0] green:c[1] blue:c[2] alpha:c[3]];
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
        if (state) [e setComputePipelineState:state];
        active_compute_state = state;
        pipeline_set = state != nil;
        if (tracing) fprintf(stderr, "trace: compute pipeline ref %u %s\n", U32(0), [objc_getAssociatedObject(state, "hvComputeIdentity") UTF8String] ?: "missing");
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
        [e setBuffers:buffers offsets:offsets withRange:NSMakeRange(index, count)];
        break;
    }
    case 207:
        if (tracing) fprintf(stderr, "trace:  cbuf %u offset now %llu\n", U32(0), (unsigned long long)U64(4));
        [e setBufferOffset:(NSUInteger)U64(4) atIndex:U32(0)];
        break;
    case 206: {
        uint32_t index = U32(0), count = U32(4);
        if (count > 128) break;
        __unsafe_unretained id<MTLTexture> items[128];
        id strong[128];
        for (uint32_t i = 0; i < count; i++) {
            strong[i] = [self get:U32(8 + i * 4) task:task];
            items[i] = strong[i];
            if (tracing) fprintf(stderr, "trace: compute tex %u ref %u ptr %p %lux%lu fmt %lu\n", index + i, U32(8 + i * 4), (__bridge void *)items[i], (unsigned long)items[i].width, (unsigned long)items[i].height, (unsigned long)items[i].pixelFormat);
        }
        if (tracing) for (uint32_t i = 0; i < count; i++) {
            id<MTLTexture> x = strong[i];
            HvObject *xo = [self object:U32(8 + i * 4) task:task];
            fprintf(stderr, "trace:  ctex %u ref %u %lux%lu fmt %lu type %u surface %s\n", index + i, U32(8 + i * 4), (unsigned long)x.width,
                    (unsigned long)x.height, (unsigned long)x.pixelFormat, xo ? xo->entry[0] & 0xff : 0, xo && xo->surface ? "yes" : "no");
        }
        [e setTextures:items withRange:NSMakeRange(index, count)];
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
        [e setSamplerStates:items withRange:NSMakeRange(index, count)];
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
        if (a.width && a.height && a.depth && b.width && b.height && b.depth &&
            active_compute_state && !objc_getAssociatedObject(active_compute_state, "hvComputeAudited")) {
            objc_setAssociatedObject(active_compute_state, "hvComputeAudited", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!compute_audits) compute_audits = [NSMutableArray new];
            [compute_audits addObject:active_compute_state];
        }
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
    uint32_t ref = U32(0), bufref = U32(4);
    uint64_t off = U64(8);
    if (tag == 451 || tag == 469) { /* how big a texture would be in a heap: {description, buffer ref, offset} */
        uint32_t at = tag == 451 ? 0x20 : 0x28;
        if (r.size < at + 12) return;
        MTLTextureDescriptor *t = tag == 451 ? descriptor_v1(r.p) : descriptor_v2(r.p);
        HvObject *to = [self object:U32(at) task:task];
        refresh_pages(self, task, to);
        uint64_t where = U64(at + 4);
        if (!to || !to->mapped || where + 16 > to->length) { [self complain:@"heap size query: no buffer"]; return; }
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
    uint8_t *out = to && to->mapped && off + 28 <= to->length ? to->mapped + off : NULL;
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
        if (!objc_getAssociatedObject(p, "hvComputeQueried")) {
            objc_setAssociatedObject(p, "hvComputeQueried", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            fprintf(stderr, "hengevm: pvg-metal: compute queried %s threads=%llu width=%llu memory=%llu\n",
                    [objc_getAssociatedObject(p, "hvComputeIdentity") UTF8String] ?: "function=unknown library=unknown",
                    (unsigned long long)v[0], (unsigned long long)v[1], (unsigned long long)v[2]);
        }
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
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.error) {
            self->failed++;
            fprintf(stderr, "hengevm: pvg-metal: command buffer: %s\n", done.error.localizedDescription.UTF8String);
        }
        if (complete) hv_pvg_lite_complete(l, ch, stamp);
    }];
    if (!lifecycle_commit(self, cb, YES)) {
        /* Only explicit VM stop cancels replay; pause preserves this call.
           No completion handler runs for an uncommitted command buffer. */
        return;
    }
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

/* YES means the caller must not emit a stamp: GPU completion owns it, or
 * ordered->faulted retains an uncommitted fatal batch. */
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
#if TARGET_OS_IPHONE
    /* A Mac companion publishes this only after atomically uploading a batch.
       Drop failed cache entries on the replay thread, before opening encoders.
       Successful GPU objects remain valid; old guest queries are not replayed. */
    double retry_now = now_seconds();
    if (trace_file && retry_now - shader_retry_check >= 1.0) {
        shader_retry_check = retry_now;
        NSString *retryPath = [[[NSString stringWithUTF8String:trace_file] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shader-retry"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:retryPath] &&
            [[NSFileManager defaultManager] removeItemAtPath:retryPath error:nil]) {
            unsigned cleared = 0;
            for (NSMutableDictionary *objects in tasks.allValues) {
                for (NSNumber *ref in objects.allKeys) {
                    HvObject *object = objects[ref];
                    unsigned type = object->entry[0] & 0xff;
                    if (!object->object && (type == OBJ_FUNCTION || type == OBJ_SERIALIZED)) {
                        [objects removeObjectForKey:ref];
                        cleared++;
                    }
                }
            }
            fprintf(stderr, "hengevm: pvg-metal: shader retry invalidated %u failed objects\n", cleared);
        }
    }
#endif
    tracing = hv_pvg_trace_on() != 0;
    probe_targets = tracing && probe_samples < 1000 ? [NSMutableDictionary new] : nil;
    if (tracing) fprintf(stderr, "trace: exec task %u, %u resources, %u buffers\n", task, nres, nbuf);
    double t_begin = now_seconds();
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = nil;
    BOOL sync_after = NO;
    NSMutableSet<HvObject *> *preparedSurfaces = [NSMutableSet new];
    NSMapTable<HvObject *, NSNumber *> *copiedWrites = [NSMapTable strongToStrongObjectsMapTable];
    for (uint32_t i = 0; i < nres; i++) {
        HvObject *o = [self object:res[i * 2] task:task];
        if (!o) continue;
        if (o->mapped) refresh_pages(self, task, o);
        if (o->surface && o->surface->iosurface) {
            HvObject *surface = o->surface;
            if (![preparedSurfaces containsObject:surface]) {
                sync_iosurface(surface, device);
                [preparedSurfaces addObject:surface];
            }
            if ((res[i * 2 + 1] & 2) && o->surface_plane < surface->plane_count && o->surface_plane < 4) {
                uint32_t mask = [[copiedWrites objectForKey:surface] unsignedIntValue];
                [copiedWrites setObject:@(mask | (1u << o->surface_plane)) forKey:surface];
            }
        }
        if (getenv("HV_PVG_TALLY") && (o->entry[0] & 0xff) == OBJ_MAPPED_TEXTURE) {
            static uint32_t seen[256];
            uint32_t f = res[i * 2 + 1] & 0xff, key = res[i * 2] & 0xff;
            if (seen[key] != f + 1) {
                seen[key] = f + 1;
                fprintf(stderr, "pvgres task %u ref %u mapped flags %x\n", task, res[i * 2], res[i * 2 + 1]);
            }
        }
        if (res[i * 2 + 1] & 1) o->guest_stale = NO, o->host_valid = NO; /* the guest wrote it */
        if (o->guest_backed && !o->host_valid) {
            if (!o->guest_stale) [self page:o toGuest:NO task:task blit:&blit commandBuffer:cb];
            o->host_valid = YES;
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
    id e = nil; /* the open encoder */
    uint32_t etype = 0;
    for (uint32_t b = 0; b < nbuf; b++) {
        uint64_t off, blen;
        memcpy(&off, bufs + b * 16, 8);
        memcpy(&blen, bufs + b * 16 + 8, 8);
        if (blen > (64u << 20) || blen < 8) continue;
        NSData *copy = activeCommand->buffers[@(b)];
        if(!copy) { NSMutableData *live=[NSMutableData dataWithLength:(NSUInteger)blen];
            if(hv_pvg_lite_task_read(lite,task,off,live.mutableBytes,(uint32_t)blen)){[self complain:@"command buffer unreadable"];continue;} copy=live; }
        if(copy.length!=blen){[self complain:@"preflight command size changed"];return NO;}
        const uint8_t *p = copy.bytes, *end = p + blen;
        uint32_t seglen, info;
        memcpy(&seglen, p, 4), memcpy(&info, p + 4, 4);
        p += 8;
        if ((info & 0xff) == 5) { /* protection options, then the real header */
            p += 8;
            if (p + 8 > end) continue;
            memcpy(&seglen, p, 4), memcpy(&info, p + 4, 4);
            p += 8;
        }
        uint32_t type = info & 0xff, cont = (info >> 8) & 0xff, more = (info >> 16) & 0xff;
        if (p + seglen < end) end = p + seglen;
        if (!cont && e) { [e endEncoding]; e = nil; }
        if (type > 2) {
            const uint8_t *q = p;
            while (q + 8 <= end) {
                uint32_t tag = *(const uint32_t *)q, sz = *(const uint32_t *)(q + 4);
                if (sz < 8 || q + sz > end) break;
                Rec r = {q + 8, sz - 8};
                if (type == 4) [self info:tag rec:r task:task];
                else [self complain:[NSString stringWithFormat:@"encoder type %u command %u (%u bytes) skipped", type, tag, sz]];
                q += sz;
            }
            continue;
        }
        if (!e && type == 1) e = [cb computeCommandEncoder], pipeline_set = NO, active_compute_state = nil;
        if (!e && type == 2) e = [cb blitCommandEncoder];
        etype = type;
        @try {
            while (p + 8 <= end) {
                uint32_t tag, size;
                memcpy(&tag, p, 4), memcpy(&size, p + 4, 4);
                if (size < 8 || p + size > end) break;
                Rec r = {p + 8, size - 8};
                if (etype == 0 && tag >= 30 && tag <= 36) { /* these describe the pass that follows */
                    if (tag == 30 && size >= 12) pre_raster_samples = U32(0);
                    else if (tag == 34 && size >= 12) pre_imageblock = U32(0);
                    else if (tag == 35 && size >= 12) pre_threadgroup = U32(0);
                    else if (tag == 36 && size >= 12) pre_tile_w = U32(0) & 0xffff, pre_tile_h = U32(0) >> 16;
                    else if (tag == 33 || tag == 32) [self complain:[NSString stringWithFormat:@"pass description %u (%u bytes) not done", tag, size]];
                } else if (etype == 0 && tag == 26) {
                    if (e) [e endEncoding];
                    e = [self beginPass:r task:task commandBuffer:cb];
                    pipeline_set = NO, tess_factors = NO;
                } else if (e) {
                    if (etype == 0) [self render:e tag:tag rec:r task:task];
                    else if (etype == 1) [self compute:e tag:tag rec:r task:task];
                    else [self blit:e tag:tag rec:r task:task];
                }
                p += size;
            }
        } @catch (NSException *x) {
            [self complain:[NSString stringWithFormat:@"exception: %@", x.reason]];
            failed++;
        }
        if (!more && e) { [e endEncoding]; e = nil; }
    }
    if (e) [e endEncoding];
    if(activeCommand && activeCommand->error){
        ordered->faulted=YES;[renderStatus setCode:2 message:activeCommand->error];
        /* Encoders have ended, but this buffer is never committed. The FIFO
           retains this fatal batch and emits no completion stamp. */
        return YES;
    }
    if (copiedWrites.count) {
        id<MTLBlitCommandEncoder> back = [cb blitCommandEncoder];
        for (HvObject *surface in copiedWrites.keyEnumerator) {
            uint32_t mask = [[copiedWrites objectForKey:surface] unsignedIntValue];
            for (uint32_t plane = 0; plane < surface->plane_count && plane < 4; plane++) {
                if (!(mask & (1u << plane))) continue;
                HvPvgSurfaceCopyback plan;
                BOOL valid = IOSurfaceGetPlaneCount(surface->iosurface) > plane &&
                    IOSurfaceGetBytesPerElementOfPlane(surface->iosurface, plane) == surface->plane_bpe[plane] &&
                    hv_pvg_surface_copyback_plan(surface->first, surface->alloc, surface->length,
                        surface->plane_from[plane], surface->plane_row[plane], surface->plane_w[plane],
                        surface->plane_h[plane], surface->plane_bpe[plane], &plan);
                if (!valid || !hv_pvg_encode_surface_copyback(back, surface->plane_textures[plane],
                        surface->object, surface->surface_shadow_buffer, &plan)) {
                    [self complain:[NSString stringWithFormat:@"copied IOSurface plane %u writeback failed layout/resource validation", plane]];
                    surface->surface_shadow_valid = NO;
                    continue;
                }
            }
        }
        [back endEncoding];
    }
    if (sync_after) { /* the guest wants these back as soon as this is done */
        id<MTLBlitCommandEncoder> back = nil;
        for (uint32_t i = 0; i < nres; i++) {
            if (!(res[i * 2 + 1] & 4)) continue;
            HvObject *o = [self object:res[i * 2] task:task];
            if (!o || !o->guest_backed) continue;
            [self page:o toGuest:YES task:task blit:&back commandBuffer:cb];
            o->guest_stale = NO;
        }
        [back endEncoding];
    }
    if (probe_targets.count) {
        id<MTLBlitCommandEncoder> probe = [cb blitCommandEncoder];
        for (NSNumber *ref in probe_targets) {
            id<MTLTexture> target = probe_targets[ref];
            if (probe_samples++ >= 1000 || !target.width || !target.height) break;
            id<MTLBuffer> rb = [device newBufferWithLength:512 options:MTLResourceStorageModeShared];
            if (!rb) continue;
            [probe copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(1, 1, 1) toBuffer:rb destinationOffset:0
            destinationBytesPerRow:256 destinationBytesPerImage:256];
            [probe copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(target.width / 2, target.height / 2, 0)
                       sourceSize:MTLSizeMake(1, 1, 1) toBuffer:rb destinationOffset:256
            destinationBytesPerRow:256 destinationBytesPerImage:256];
            uint32_t seq = probe_samples;
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                if (done.error) return;
                double corner[4], center[4];
                if (target.pixelFormat == MTLPixelFormatRGBA16Float) {
                    const _Float16 *a = rb.contents;
                    const _Float16 *b = (const _Float16 *)((const uint8_t *)rb.contents + 256);
                    for (int i = 0; i < 4; i++) corner[i] = a[i], center[i] = b[i];
                } else {
                    const uint8_t *a = rb.contents;
                    const uint8_t *b = (const uint8_t *)rb.contents + 256;
                    for (int i = 0; i < 4; i++) {
                        int channel = i == 0 ? 2 : i == 2 ? 0 : i;
                        corner[i] = a[channel] / 255.0;
                        center[i] = b[channel] / 255.0;
                    }
                }
                fprintf(stderr, "trace: probe seq %u ref %u tex %p %lux%lu fmt %lu corner %.3f %.3f %.3f %.3f center %.3f %.3f %.3f %.3f\n",
                        seq, ref.unsignedIntValue, (__bridge void *)target, (unsigned long)target.width, (unsigned long)target.height,
                        (unsigned long)target.pixelFormat, corner[0], corner[1], corner[2], corner[3],
                        center[0], center[1], center[2], center[3]);
            }];
        }
        [probe endEncoding];
        probe_targets = nil;
    }
    if (compute_audits.count) {
        NSArray *audited = [compute_audits copy];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            for (id state in audited) {
                fprintf(stderr, "hengevm: pvg-metal: compute %s %s\n",
                        !done.error && done.status == MTLCommandBufferStatusCompleted ? "completed" : "dispatch-failed",
                        [objc_getAssociatedObject(state, "hvComputeIdentity") UTF8String] ?: "function=unknown library=unknown");
            }
        }];
        compute_audits = nil;
    }
    double t1 = now_seconds();
    [self commit:cb channel:ch stamp:stamp complete:YES];
    for (HvObject *surface in copiedWrites.keyEnumerator) surface->surface_pending = cb;
    double t2 = now_seconds();
    encode_time += t1 - t_begin, gpu_wait_time += t2 - t1;
    if (++execs % 2000 == 0) {
        static double t0;
        if (!t0) t0 = now_seconds();
        fprintf(stderr, "hengevm: pvg-metal: %llu execs, %llu draws, %llu failed, %llu synced, %llu remaps, %.0f s; encoding %.2f s, waiting for the GPU %.2f s\n", (unsigned long long)execs, (unsigned long long)draws, (unsigned long long)failed, (unsigned long long)synced, (unsigned long long)remaps, now_seconds() - t0, encode_time, gpu_wait_time);
        encode_time = gpu_wait_time = 0;
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
    if (n < 0x2c) return;
    uint64_t off, stride;
    memcpy(&off, a + 2, 8), memcpy(&stride, a + 6, 8);
    uint16_t w, h, hx, hy;
    memcpy(&w, (const uint8_t *)a + 0x20, 2), memcpy(&h, (const uint8_t *)a + 0x22, 2);
    memcpy(&hx, (const uint8_t *)a + 0x24, 2), memcpy(&hy, (const uint8_t *)a + 0x26, 2);
    if (!w || !h || w > 512 || h > 512 || stride < (uint64_t)w * 4 || stride > 8192) return;
    uint8_t *bits = malloc((size_t)stride * h);
    if (hv_pvg_lite_task_read(lite, 0, off, bits, (uint32_t)stride * h)) {
        free(bits);
        [self complain:@"pointer image unreadable"];
        return;
    }
    free(cursor);
    MTLTextureDescriptor *ct = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    ct.storageMode = MTLStorageModeShared;
    id<MTLTexture> glyph = [device newTextureWithDescriptor:ct];
    [glyph replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bits bytesPerRow:(NSUInteger)stride];
    os_unfair_lock_lock(&screen_lock);
    cursor = bits, cursor_w = w, cursor_h = h, cursor_stride = (uint32_t)stride, cursor_hot_x = hx, cursor_hot_y = hy;
    cursor_tex = glyph;
    os_unfair_lock_unlock(&screen_lock);
    if (getenv("HV_PVG_CURSOR_LOG")) fprintf(stderr, "pvgcursor glyph %ux%u hot %d,%d stride %u first alpha %u\n", w, h, hx, hy, (uint32_t)stride, bits[(size_t)(h / 2) * stride + (size_t)(w / 2) * 4 + 3]);
    [self drawCursor];
}

- (BOOL)hasDisplayLayer {
    os_unfair_lock_lock(&screen_lock);
    BOOL attached = layer != nil;
    os_unfair_lock_unlock(&screen_lock);
    return attached;
}

/* Puts back what the pointer covered, and draws it where the shared page says it is now. */
- (void)drawCursor {
    if ([self hasDisplayLayer]) {
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
    const int scale = cursor_scale();
    int x = (int)(where & 0xffff) - cursor_hot_x * scale, y = (int)(where >> 16) - cursor_hot_y * scale;
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

static NSString *const screen_shaders = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 at [[position]]; float2 uv; };\n"
    "vertex V screen_v(uint i [[vertex_id]], constant float4 &rect [[buffer(0)]]) {\n"
    "  float2 c = float2(i & 1, (i >> 1) & 1);\n"
    "  V o; o.at = float4(rect.xy + c * rect.zw, 0, 1); o.uv = float2(c.x, 1 - c.y); return o; }\n"
    "fragment float4 screen_plain(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return float4(t.sample(s, v.uv).rgb, 1); }\n"
    "fragment float4 screen_linear(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant uint &mode [[buffer(0)]]) {\n"
    "  float3 c = saturate(t.sample(s, v.uv).rgb);\n"
    "  if (mode == 1) c = select(1.055 * powr(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);\n"
    "  return float4(c, 1); }\n"
    "fragment float4 screen_cursor(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.sample(s, v.uv); }\n";

- (BOOL)prepareScreenForLayer:(CAMetalLayer *)target {
    if (!screen_pipe || !linear_pipe || !cursor_pipe) {
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:screen_shaders options:nil error:&err];
        if (!lib) { [self complain:[NSString stringWithFormat:@"screen shaders: %@", err.localizedDescription]]; return NO; }
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"screen_v"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        d.fragmentFunction = [lib newFunctionWithName:@"screen_plain"];
        screen_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"screen_linear"];
        linear_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"screen_cursor"];
        d.colorAttachments[0].blendingEnabled = YES;
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        cursor_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
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
- (void)kickPresenter:(BOOL)fresh {
    /* screen_lock held */
    if (atomic_load(&stopping) || presenter_barrier || !hv_lifecycle_allowed(&hv_app_lifecycle) || !hv_lifecycle_allowed(&hv_cpu_lifecycle)) return;
    if (fresh) screen_requests++;
    if (presenter_running || !layer || !screen_tex || drawable_retry_pending) return;
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

- (void)showOnLayer:(uint64_t)mapping {
    HvObject *surface = hv_pvg_lite_compact_surfaces(lite) ? [self currentSurface:mapping] : (surfaces[@(mapping)] ?: [self newSurface:mapping]);
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
        if (surface->iosurface && surface->plane_count == 1)
            surface->scanout = [device newTextureWithDescriptor:t iosurface:surface->iosurface plane:0];
        else if (linear_texture_fits(device, t, surface->first, surface->row, ((id<MTLBuffer>)surface->object).length))
            surface->scanout = [(id<MTLBuffer>)surface->object newTextureWithDescriptor:t offset:surface->first bytesPerRow:surface->row];
        if (!surface->scanout) { [self complain:[NSString stringWithFormat:@"no scanout for surface %llu, row %llu", mapping, surface->row]]; return; }
    }
    if (surface->iosurface && surface->plane_count == 1) sync_iosurface(surface, device);
    os_unfair_lock_lock(&screen_lock);
    screen_tex = surface->scanout, screen_half = half, screen_w = surface->surface_w, screen_h = surface->surface_h;
    screen_dirty = YES;
    [self kickPresenter:YES];
    os_unfair_lock_unlock(&screen_lock);
}

/* The pointer moved or changed: the screen again, with no need to go through the GPU queue's worker. */
- (void)screenChanged {
    os_unfair_lock_lock(&screen_lock);
    if (screen_tex) {
        screen_dirty = YES;
        [self kickPresenter:YES];
    }
    os_unfair_lock_unlock(&screen_lock);
}

- (void)presentLoop {
    for (;;) @autoreleasepool {
        os_unfair_lock_lock(&screen_lock);
        if (!screen_dirty || !layer || presenter_barrier || atomic_load(&stopping) || !hv_lifecycle_allowed(&hv_app_lifecycle) || !hv_lifecycle_allowed(&hv_cpu_lifecycle)) {
            presenter_running = NO;
            os_unfair_lock_unlock(&screen_lock);
            return;
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
        CGSize want = CGSizeMake(W, H);
        if (!CGSizeEqualToSize(target.drawableSize, want)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            target.drawableSize = want;
            [CATransaction commit];
        }
        id<CAMetalDrawable> drawable = [target nextDrawable]; /* the wait is here */
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
        cw0 = cursor_w, ch0 = cursor_h, hx = cursor_hot_x, hy = cursor_hot_y;
        BOOL same_target = layer_generation == generation && layer == target;
        BOOL same_size = screen_w == W && screen_h == H;
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
        id<MTLCommandBuffer> cb = [queue commandBuffer];
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
        const uint8_t *page = hv_pvg_lite_display_page(lite);
        uint32_t where = page ? __atomic_load_n((const uint32_t *)(page + 0xe00), __ATOMIC_ACQUIRE) : 0xffffffff;
        if (ctex && where != 0xffffffff && (shown || page[0xe04])) {
            const float scale = cursor_scale();
            float x = (float)(where & 0xffff) - hx * scale, y = (float)(where >> 16) - hy * scale;
            float cw = cw0 * scale, ch = ch0 * scale;
            float r[4] = {x / W * 2 - 1, 1 - (y + ch) / H * 2, cw / W * 2, ch / H * 2};
            [e setRenderPipelineState:cursor_pipe];
            [e setVertexBytes:r length:sizeof r atIndex:0];
            [e setFragmentTexture:ctex atIndex:0];
            NSNumber *sharpSetting = [[NSUserDefaults standardUserDefaults] objectForKey:@"henge.cursor.sharp"];
            [e setFragmentSamplerState:sharpSetting && !sharpSetting.boolValue ? screen_sampler : cursor_sampler atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [e endEncoding];
        if (cp.on) cp_capture_post(self, drawable.texture, W, H, cb);
#if !TARGET_OS_IPHONE
        if (getenv("HV_PVG_GPU_TEST")) { /* the same pixels for a screenshot: this is the path a phone runs */
            NSUInteger bytes = (NSUInteger)W * H * 4;
            if (!test_readback || test_readback.length < bytes) test_readback = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> rb = test_readback;
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                      toBuffer:rb destinationOffset:0 destinationBytesPerRow:(NSUInteger)W * 4 destinationBytesPerImage:bytes];
            [b endEncoding];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                (void)done;
                dispatch_async(self->worker, ^{
                    if (!self->frame || self->frame_w != W || self->frame_h != H) {
                        self->frame = malloc((size_t)W * H * 4), self->frame_w = W, self->frame_h = H;
                    }
                    memcpy(self->frame, rb.contents, (size_t)W * H * 4);
                    self->frames++;
                });
            }];
        }
#endif
        // Serialize the final check and commit with set_layer: a switch that has
        // returned must not be followed by a commit to its old target.
        os_unfair_lock_lock(&screen_lock);
        BOOL submitted = NO;
        if (layer_generation == generation && layer == target && !presenter_barrier && hv_lifecycle_allowed(&hv_app_lifecycle) && hv_lifecycle_allowed(&hv_cpu_lifecycle)) {
            [cb presentDrawable:drawable];
            if (lifecycle_commit(self, cb, NO)) { gpu_frames++; submitted = YES; }
            else {
                // Presentation may coalesce; guest replay may not. Do not wait
                // for foreground or another submission while holding screen_lock.
                screen_dirty = YES;
                presenter_running = NO;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), presenter, ^{
                    os_unfair_lock_lock(&self->screen_lock);
                    [self kickPresenter:NO];
                    os_unfair_lock_unlock(&self->screen_lock);
                });
                os_unfair_lock_unlock(&screen_lock);
                return;
            }
        } else {
            screen_dirty = YES;
        }
        os_unfair_lock_unlock(&screen_lock);
        if (submitted) [cb waitUntilScheduled];
    }
}

/* What the display should show: at most a few times a second by CPU, for tests and the boot's first frames. */
- (void)present:(uint64_t)mapping {
    if (atomic_load(&stopping)) return;
    id<MTLTexture> fallback = fallback_textures[@(mapping)];
    seeded_target_since_present = nil;
    if (fallback && fallback.width >= 800 && fallback.height >= 600)
        [scanout_mappings addObject:@(mapping)];
    if (getenv("HV_PVG_TRACE_FILE")) {
        static uint64_t prior_mapping = UINT64_MAX;
        static void *prior_texture;
        HvObject *present_surface = surfaces[@(mapping)];
        id<MTLTexture> current = fallback ?: (present_surface ? present_surface->scanout : nil);
        void *current_texture = (__bridge void *)current;
        if (mapping != prior_mapping || current_texture != prior_texture) {
            fprintf(stderr, "hengevm: pvg-metal: present map %llu tex %p fallback %d gpu_frames %llu\n",
                    (unsigned long long)mapping, current_texture, fallback != nil,
                    (unsigned long long)gpu_frames);
            prior_mapping = mapping;
            prior_texture = current_texture;
        }
    }
    if (fallback && [self hasDisplayLayer]) {
        last_fallback_scanout = fallback;
        os_unfair_lock_lock(&screen_lock);
        on_screen = mapping;
        screen_tex = fallback;
        screen_w = (uint32_t)fallback.width;
        screen_h = (uint32_t)fallback.height;
        screen_half = fallback.pixelFormat == MTLPixelFormatRGBA16Float;
        screen_dirty = YES;
        [self kickPresenter:YES];
        os_unfair_lock_unlock(&screen_lock);
        return;
    }
    double now = now_seconds();
    on_screen = mapping;
    if ([self hasDisplayLayer]) {
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
    HvObject *surface = hv_pvg_lite_compact_surfaces(lite) ? [self currentSurface:mapping] : (surfaces[@(mapping)] ?: [self newSurface:mapping]);
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

/* Snapshot descriptor/function reads, then reuse them through parked retries.
 * Other resources remain guest-owned until the withheld completion stamp. */
- (int)shaderRead:(uint64_t)offset task:(uint32_t)task to:(void *)to length:(uint32_t)n {
    if(!activeCommand)return hv_pvg_lite_task_read(lite,task,offset,to,n);
    NSString *key=[NSString stringWithFormat:@"%u:%llu:%u",task,offset,n];
    NSData *saved=activeCommand->reads[key];
    if(saved){memcpy(to,saved.bytes,n);return 0;}
    if(n>(128u<<20)-MIN(activeCommand->snapshotBytes,(NSUInteger)(128u<<20))){activeCommand->error=@"shader snapshot exceeds128MiB";return -1;}
    if(hv_pvg_lite_task_read(lite,task,offset,to,n))return -1;
    activeCommand->reads[key]=[NSData dataWithBytes:to length:n];activeCommand->snapshotBytes+=n;return 0;
}

- (void)preflightReference:(uint32_t)ref task:(uint32_t)task {
    if(!ref||activeCommand->error)return;
    uint64_t list=hv_pvg_lite_task_objects(lite,task);uint32_t e[3];
    if(!list||[self shaderRead:list+(uint64_t)ref*12 task:task to:e length:12]){activeCommand->error=@"preflight object entry unreadable";return;}
    unsigned type=e[0]&255;if(type!=OBJ_FUNCTION&&type!=OBJ_SERIALIZED)return;
    HvObject *o=[self object:ref task:task];
    if((!o||!o->object)&&!preflightWaiting&&!activeCommand->error)
        activeCommand->error=[NSString stringWithFormat:@"shader/pipeline ref%u unavailable without pending conversion",ref];
}

- (HvReplayReadiness)preflightCommand:(HvReplayCommand*)item {
#if !TARGET_OS_IPHONE
    return HvReplayReady;
#else
    if(item->error)return HvReplayFault;
    const uint32_t *cmd=item->command.bytes;NSUInteger len=item->command.length;
    if(len<12){item->error=@"short command";return HvReplayFault;}
    uint32_t op=cmd[0]&0xffff,skip=(cmd[0]>>16)*8;
    if(op!=0x43&&op!=0x45&&op!=0x37)return HvReplayReady;
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    if(!shaderProvider&&!shaderProviderError&&!hv_shader_profile_required(documents))return HvReplayReady;
    /* Ready results are pinned by the packet; pending capacity is retried without
       duplicating a running compile or trusting an evictable provider entry. */
    if(item->localSources.count){
        activeCommand=item;
        @try{
            for(NSString *source in item->localSources.allKeys){
                HGOnDeviceShaderResult *result=[self requestLocalShader:item->localSources[source] sourceSHA:source];
                if(item->error)return HvReplayFault;
                if(result.status!=HGOnDeviceShaderReady)return HvReplayPark;
            }
        }@finally{activeCommand=nil;}
    }
    NSDictionary *config=hv_shader_compiler_config(documents);
    if(item->awaitingLease&&!hv_shader_lease(documents,config[@"recipe"]))return HvReplayPark;
    item->awaitingLease=NO;
    for(NSString *source in item->requests.allKeys){
        NSDictionary *request=item->requests[source];
        NSDictionary *state=hv_shader_poll_request(documents,request);
        NSString *kind=state[@"state"];
        if([kind isEqual:@"ready"]){[item->requests removeObjectForKey:source];continue;}
        if([kind isEqual:@"failed"]||[kind isEqual:@"stale"]){item->error=[NSString stringWithFormat:@"shader %@ %@: %@",source,kind,state[@"receipt"][@"error"]?:@""];return HvReplayFault;}
        if([kind isEqual:@"offline"]){NSDictionary *renewed=hv_shader_enqueue_request(documents,source,nil);if(renewed)item->requests[source]=renewed;}
        return HvReplayPark;
    }
    if(len<12ull+skip+12){item->error=@"short exec";return HvReplayFault;}
    const uint32_t *a=(const uint32_t*)((const uint8_t*)cmd+12+skip);
    uint32_t task=a[0],nres=a[1],nbuf=a[2],stride=op==0x37?24:8;
    if(task>=512||12ull+nres*(uint64_t)stride+nbuf*16ull>len-12-skip){item->error=@"invalid exec ranges";return HvReplayFault;}
    if(hv_pvg_lite_task_generation(lite,task)!=item->generation){item->error=@"task generation changed while accepted command was pending; refusing wrong-owner replay";return HvReplayFault;}
    activeCommand=item;preflighting=YES;preflightWaiting=NO;
    @try{
        /* Failed preflight objects are provisional. Retain all successful objects. */
        NSMutableDictionary *objects=tasks[@(task)];
        for(NSNumber *ref in objects.allKeys){HvObject *o=objects[ref];if(!o->object&&((o->entry[0]&255)==OBJ_FUNCTION||(o->entry[0]&255)==OBJ_SERIALIZED))[objects removeObjectForKey:ref];}
        const uint8_t *resources=(const uint8_t*)(a+3),*buffers=resources+(uint64_t)nres*stride;
        for(uint32_t i=0;i<nres;i++){uint32_t ref;memcpy(&ref,resources+(uint64_t)i*stride,4);[self preflightReference:ref task:task];}
        for(uint32_t b=0;b<nbuf&&!item->error;b++){
            uint64_t off,blen;memcpy(&off,buffers+b*16,8);memcpy(&blen,buffers+b*16+8,8);
            if(blen<8||blen>(64u<<20)){item->error=@"invalid command segment size";break;}
            NSData *copy=item->buffers[@(b)];
            if(!copy){if(blen>(128u<<20)-MIN(item->snapshotBytes,(NSUInteger)(128u<<20))){item->error=@"command snapshots exceed128MiB";break;}
                NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)blen];if(hv_pvg_lite_task_read(lite,task,off,data.mutableBytes,(uint32_t)blen)){item->error=@"preflight command segment unreadable";break;}
                item->buffers[@(b)]=copy=data;item->snapshotBytes+=blen;}
            const uint8_t *p=copy.bytes,*end=p+copy.length;uint32_t seglen,info;memcpy(&seglen,p,4);memcpy(&info,p+4,4);p+=8;
            if((info&255)==5){if(end-p<16){item->error=@"short protection segment";break;}p+=8;memcpy(&seglen,p,4);memcpy(&info,p+4,4);p+=8;}
            if(seglen<(uint64_t)(end-p))end=p+seglen;
            uint32_t type=info&255;
            while(end-p>=8){uint32_t tag,size;memcpy(&tag,p,4);memcpy(&size,p+4,4);if(size<8||size>(uint64_t)(end-p)){item->error=@"malformed preflight record";break;}
                BOOL reference=(type==0&&tag==116)||(type==1&&tag==208)||(type==4&&tag!=451&&tag!=469);
                if(reference){if(size<12){item->error=@"short pipeline/query reference";break;}uint32_t ref;memcpy(&ref,p+8,4);[self preflightReference:ref task:task];}
                p+=size;
            }
        }
    }@catch(NSException *exception){item->error=[NSString stringWithFormat:@"preflight exception: %@",exception.reason];}
    @finally{preflighting=NO;activeCommand=nil;}
    if(item->error){[self complain:item->error];return HvReplayFault;}
    return preflightWaiting?HvReplayPark:HvReplayReady;
#endif
}

- (void)pumpCommands {
    if(!hv_lifecycle_wait_stoppable(&hv_app_lifecycle,&stopping)){
        [ordered stop];activeCommand=nil;return;
    }
    __weak HvReplay *weak=self;
    [ordered pump:^HvReplayReadiness(HvReplayCommand *item){
        /* Check every head: app activity can change during a FIFO pump. */
        if(!hv_lifecycle_wait_stoppable(&hv_app_lifecycle,&self->stopping)){
            [self->ordered stop];self->activeCommand=nil;return HvReplayPark;
        }
        if(item->taskView)hv_pvg_lite_use_task_view(self->lite,item->taskView.bytes);
        @try{
            HvReplayReadiness readiness=[self preflightCommand:item];
            if(readiness==HvReplayPark)[self->renderStatus setCode:1 message:item->awaitingLease
                ? @"Waiting for the shader compiler to connect."
                : @"Preparing a shader required by this Mac. Graphics will continue when it is ready."];
            else if(readiness==HvReplayFault)[self->renderStatus setCode:2 message:item->error?:@"A required graphics operation could not be prepared."];
            else [self->renderStatus setCode:0 message:nil];
            return readiness;
        }@finally{hv_pvg_lite_use_task_view(self->lite,NULL);}
    } execute:^(HvReplayCommand *item){
        self->activeCommand=item;
        if(item->taskView)hv_pvg_lite_use_task_view(self->lite,item->taskView.bytes);
        @try{[self performCommand:item];}@finally{self->activeCommand=nil;hv_pvg_lite_use_task_view(self->lite,NULL);}
    } barrier:^(HvReplayCommand *item){
        /* No later FIFO entry commits while this marker waits for prior work.
           Final presenter commits hold this same lock: close admission before
           observing the group, including a drawable already being prepared. */
        os_unfair_lock_lock(&self->screen_lock);
        self->presenter_barrier=YES;
        os_unfair_lock_unlock(&self->screen_lock);
        /* A drawable can be prepared outside screen_lock. Let that serial
           presenter reach its guarded final check and exit before releasing
           mappings, even if the completion group was already empty. */
        dispatch_async(self->presenter,^{
        dispatch_group_notify(self->completions,self->worker,^{
            HvReplay *r=weak;if(!r||r->ordered->stopped)return;
            if(r->ordered->entries.firstObject!=item)return;
            if(atomic_load(&r->stopping)||atomic_load(&hv_app_lifecycle.cancelled)){
                [r->ordered stop];r->activeCommand=nil;return;
            }
            [r->ordered->entries removeObjectAtIndex:0];r->ordered->waiting=NO;
            atomic_fetch_sub(&r->ordered->reserved,item->command.length);[item complete:0];
            /* Keep presentation suppressed through mapper unmap/IRQ publication. */
            os_unfair_lock_lock(&r->screen_lock);
            r->presenter_barrier=NO;[r kickPresenter:NO];
            os_unfair_lock_unlock(&r->screen_lock);
            [r pumpCommands];
        });
        });
    }];
    if(ordered->faulted){[self complain:@"ordered replay stopped on unresolved shader error; no incomplete stamp acknowledged"];return;}
    if(ordered->entries.count&&!ordered->waiting&&!pollScheduled){
        pollScheduled=YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),worker,^{
            HvReplay *r=weak;if(!r)return;r->pollScheduled=NO;
            if(!atomic_load(&r->stopping))[r pumpCommands];
        });
    }
}

- (void)performCommand:(HvReplayCommand *)item {
    HvReplay *r=self; HvPvgLite *lite=self->lite; uint32_t ch=item->channel;
    uint32_t len=(uint32_t)item->command.length;const uint32_t *cmd=item->command.bytes;
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
                } else if (task_cache_lifecycle(r->tasks, op, args, n)) {
                    /* Ordered invalidation; guest stamps still follow normal completion. */
                } else {
                    hv_pvg_lite_command(lite, cmd, len);
                    if (op == 8 && n >= 16) {
                        uint64_t shown = (uint64_t)args[3] << 32 | args[2];
                        if (r->tracing) fprintf(stderr, "trace: swap to %llu\n", shown);
                        cp_note_swap(r, shown, args, n);
                        [r present:shown];
                    }
                    if (op == 4) [r cursorGlyph:args length:n];
                    if (op == 5 && n >= 8) {
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
            if(item->error){
                r->ordered->faulted=YES;[r->renderStatus setCode:2 message:item->error];
            }else if (!gpu_completes) [r finishChannel:ch stamp:cmd[2]];

}

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
        r->completions = dispatch_group_create();
        r->ordered=[HvOrderedReplay new];
        r->renderStatus=[HvRenderStatus new];
#if TARGET_OS_IPHONE
        NSError *providerError=nil;
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        r->shaderProvider=[[HGOnDeviceShaderProvider alloc]initWithDocuments:documents error:&providerError];
        if(!r->shaderProvider)r->shaderProviderError=providerError.localizedDescription?:@"The local shader compiler could not start.";
#endif
        r->device = dev;
        r->queue = [dev newCommandQueueWithMaxCommandBufferCount:64];
        r->worker = dispatch_queue_create("hengevm.pvg", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        r->presenter = dispatch_queue_create("hengevm.present", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        r->screen_lock = OS_UNFAIR_LOCK_INIT;
        r->tasks = [NSMutableDictionary new];
        r->mapped_textures = [NSMutableDictionary new];
        r->fallback_textures = [NSMutableDictionary new];
        fprintf(stderr, "hengevm: pvg-metal: unconditional mapped fallback diagnostics enabled\n");
        r->scanout_mappings = [NSMutableSet new];
        r->surfaces = [NSMutableDictionary new];
        r->planar = [NSMutableDictionary new];
        r->planar_uses = [NSMutableDictionary new];
        r->complaints = [NSMutableSet new];
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
        fprintf(stderr, "hengevm: pvg-metal: drawing on %s\n", dev.name.UTF8String);
        return (HvPvgMetal *)CFBridgingRetain(r);
    }
}



void hv_pvg_metal_destroy(HvPvgMetal *m) {
    if (!m) return;
    @autoreleasepool {
        HvReplay *r = CFBridgingRelease(m);
        atomic_store(&r->stopping, 1);
#if TARGET_OS_IPHONE
        [r->shaderProvider invalidate];
#endif
        pthread_cond_broadcast(&hv_app_lifecycle.cv);
        if (r->shot_timer) { dispatch_source_cancel(r->shot_timer); r->shot_timer = nil; }
        if (cp.timer) { dispatch_source_cancel(cp.timer); cp.timer = nil; }
        os_unfair_lock_lock(&r->screen_lock);
        r->layer = nil;
        r->layer_generation++;
        r->screen_dirty = NO;
        os_unfair_lock_unlock(&r->screen_lock);
        /* No CPU can enqueue more work. Delayed presentation blocks see
           stopping before touching guest memory; already queued work drains. */
        dispatch_sync(r->worker, ^{ r->late = NO; [r->ordered stop]; r->activeCommand=nil; });
        dispatch_sync(r->presenter, ^{});
        /* Wait only for previously submitted GPU work; never submit a
           background teardown fence. lifecycle_commit owns the group. */
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
        /* GPU completions may have enqueued a final readback on the worker. */
        dispatch_sync(r->worker, ^{
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

int hv_pvg_metal_render_status(HvPvgMetal *m,char *message,uint32_t length){
    if(!m){if(message&&length)message[0]=0;return 0;}
    HvReplay *r=(__bridge HvReplay*)m;return [r->renderStatus copyMessage:message length:length];
}
int hv_pvg_metal_reserve(HvPvgMetal *m,uint32_t length) {
    HvReplay *r=(__bridge HvReplay*)m;
    return !atomic_load(&r->stopping) && [r->ordered reserve:length];
}
void hv_pvg_metal_submit(HvPvgMetal *m,HvPvgLite *lite,uint32_t ch,uint32_t *cmd,uint32_t len) {
    HvReplay *r=(__bridge HvReplay*)m;HvReplayCommand *item=[HvReplayCommand new];
    item->command=[NSData dataWithBytesNoCopy:cmd length:len freeWhenDone:YES];item->channel=ch;
    uint32_t skip=(cmd[0]>>16)*8,op=cmd[0]&0xffff;
    if(((op==0x43||op==0x45||op==0x37)&&len>=12ull+skip+12)||((op==0x35||op==0x3e)&&len>=12ull+skip+8)){
        const uint32_t *args=(const uint32_t*)((const uint8_t*)cmd+12+skip);item->task=args[0];
        HvPvgTaskView view;
        if(!hv_pvg_lite_task_view(lite,item->task,&view)){item->generation=view.generation;item->taskView=[NSData dataWithBytes:&view length:sizeof view];}
        else item->error=@"task metadata unavailable at command acceptance";
    }
    dispatch_async(r->worker,^{@autoreleasepool{[r->ordered enqueue:item];[r pumpCommands];}});
}
void hv_pvg_metal_drain(HvPvgMetal *m,void(*done)(void*,int),void *opaque){
    HvReplay *r=(__bridge HvReplay*)m;HvReplayCommand *item=[HvReplayCommand new];item->barrier=done;item->opaque=opaque;
    dispatch_async(r->worker,^{[r->ordered enqueue:item];[r pumpCommands];});
}

void hv_pvg_metal_set_layer(HvPvgMetal *m, void *layer) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    CAMetalLayer *l = (__bridge CAMetalLayer *)layer;
    // Invalidate immediately, even when the guest GPU worker has a backlog.
    os_unfair_lock_lock(&r->screen_lock);
    r->layer_generation++; /* reattaching the same layer also wakes a stopped presenter */
    r->layer = l;
    r->drawable_retry_pending = NO;
    r->drawable_retry_deadline = r->drawable_retry_cooldown = 0;
    r->screen_dirty = YES;
    [r kickPresenter:YES];
    os_unfair_lock_unlock(&r->screen_lock);
    dispatch_async(r->worker, ^{
        if (hv_lifecycle_allowed(&hv_app_lifecycle) && r->on_screen) [r present:r->on_screen];
    });
}

uint64_t hv_pvg_metal_gpu_frames(HvPvgMetal *m) {
    return m ? ((__bridge HvReplay *)m)->gpu_frames : 0;
}

void hv_pvg_metal_cursor_moved(HvPvgMetal *m) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    if ([r hasDisplayLayer]) { /* no need to queue behind the guest's GPU work */
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

void hv_pvg_metal_mapper(HvPvgMetal *m,uint32_t operation,uint32_t mapping,uint64_t completed_index) {
    HvReplay *r=(__bridge HvReplay*)m;HvReplayCommand *item=[HvReplayCommand new];
    uint32_t bytes[4]={operation,mapping,(uint32_t)completed_index,(uint32_t)(completed_index>>32)};
    item->command=[NSData dataWithBytes:bytes length:sizeof bytes];
    __weak HvReplay *weak=r;
    item->completion=^(int cancelled){HvReplay *r=weak;if(cancelled||!r||atomic_load(&r->stopping))return;
        if(operation==2){
        release_planar_alias(r->planar, r->planar_uses, r->surfaces[@(mapping)]);
        id<MTLTexture> fallback = r->fallback_textures[@(mapping)];
        if (fallback && getenv("HV_PVG_TRACE_FILE"))
            fprintf(stderr, "hengevm: pvg-metal: fallback unmap %u tex %p\n", mapping,
                    (__bridge void *)fallback);
        [r->surfaces removeObjectForKey:@(mapping)];
        [r->mapped_textures removeObjectForKey:@(mapping)];
        /* A mapper ID may be assigned to a new IOSurface after unmap.  A
           private fallback belongs to the old surface, even when the next
           surface happens to have the same size and pixel format. */
        [r->fallback_textures removeObjectForKey:@(mapping)];
        }
        hv_pvg_lite_mapper_complete(r->lite,completed_index);
    };
    dispatch_async(r->worker,^{[r->ordered enqueue:item];[r pumpCommands];});
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

@interface HvReplay (Resume)
- (void)page:(HvObject *)o toGuest:(BOOL)down task:(uint32_t)task blit:(id<MTLBlitCommandEncoder> *)blit commandBuffer:(id<MTLCommandBuffer>)cb;
@end

/* Instant resume: the CPUs are stopped. Finish what the guest handed over, then copy what only the GPU holds (it drew
   into private memory and the guest has not asked for it back) into guest memory, where a replay made after a restore
   reads it from. A texture in a heap goes with its heap's bytes, as the heap is what is made again from guest memory. */
void hv_pvg_metal_quiesce(HvPvgMetal *m) {
    if (!m) return;
    HvReplay *r = (__bridge HvReplay *)m;
    @autoreleasepool {
        dispatch_sync(r->worker, ^{});
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
        dispatch_sync(r->worker, ^{
            id<MTLCommandBuffer> cb = nil;
            id<MTLBlitCommandEncoder> blit = nil;
            unsigned copied = 0;
            for (NSNumber *task in r->tasks) {
                NSMutableDictionary<NSNumber *, HvObject *> *objs = r->tasks[task];
                for (NSNumber *ref in objs) {
                    HvObject *o = objs[ref];
                    if (!o->guest_backed || !o->host_valid || !o->guest_stale) continue;
                    if (o->parent && o->parent->heap_whole) continue;
                    if (!cb) cb = [r->queue commandBuffer];
                    [r page:o toGuest:YES task:task.unsignedIntValue blit:&blit commandBuffer:cb];
                    o->guest_stale = NO;
                    copied++;
                }
            }
            [blit endEncoding];
            if (cb) {
                [cb commit];
                [cb waitUntilCompleted];
            }
            fprintf(stderr, "hengevm: pvg-metal: quiesced, %u GPU-only objects copied to guest memory\n", copied);
        });
        dispatch_group_wait(r->completions, DISPATCH_TIME_FOREVER);
    }
}

typedef struct DisplayState {
    uint64_t on_screen;
    uint32_t cursor_w, cursor_h, cursor_stride, cursor_shown;
    int32_t hot_x, hot_y;
} DisplayState;

size_t hv_pvg_metal_display_state(HvPvgMetal *m, void *out, size_t cap) {
    HvReplay *r = (__bridge HvReplay *)m;
    __block size_t need = 0;
    dispatch_sync(r->worker, ^{
        os_unfair_lock_lock(&r->screen_lock);
        size_t bits = r->cursor ? (size_t)r->cursor_stride * r->cursor_h : 0;
        need = sizeof(DisplayState) + bits;
        if (out && cap >= need) {
            DisplayState d = {.on_screen = r->on_screen, .cursor_w = bits ? r->cursor_w : 0, .cursor_h = bits ? r->cursor_h : 0,
                              .cursor_stride = bits ? r->cursor_stride : 0, .cursor_shown = r->cursor_shown,
                              .hot_x = r->cursor_hot_x, .hot_y = r->cursor_hot_y};
            memcpy(out, &d, sizeof d);
            if (bits) memcpy((uint8_t *)out + sizeof d, r->cursor, bits);
        }
        os_unfair_lock_unlock(&r->screen_lock);
    });
    return need;
}

void hv_pvg_metal_set_display_state(HvPvgMetal *m, const void *in, size_t len) {
    if (!m || len < sizeof(DisplayState)) return;
    HvReplay *r = (__bridge HvReplay *)m;
    DisplayState d;
    memcpy(&d, in, sizeof d);
    size_t bits = (size_t)d.cursor_stride * d.cursor_h;
    if (len < sizeof d + bits || d.cursor_w > 512 || d.cursor_h > 512 || (bits && d.cursor_stride < d.cursor_w * 4)) bits = 0;
    uint8_t *copy = bits ? malloc(bits) : NULL;
    if (copy) memcpy(copy, (const uint8_t *)in + sizeof d, bits);
    dispatch_sync(r->worker, ^{
        @autoreleasepool {
            id<MTLTexture> glyph = nil;
            if (copy) {
                MTLTextureDescriptor *ct = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:d.cursor_w height:d.cursor_h mipmapped:NO];
                ct.storageMode = MTLStorageModeShared;
                glyph = [r->device newTextureWithDescriptor:ct];
                [glyph replaceRegion:MTLRegionMake2D(0, 0, d.cursor_w, d.cursor_h) mipmapLevel:0 withBytes:copy bytesPerRow:d.cursor_stride];
            }
            os_unfair_lock_lock(&r->screen_lock);
            if (copy) {
                free(r->cursor);
                r->cursor = copy, r->cursor_w = d.cursor_w, r->cursor_h = d.cursor_h, r->cursor_stride = d.cursor_stride;
                r->cursor_hot_x = d.hot_x, r->cursor_hot_y = d.hot_y;
                r->cursor_tex = glyph;
            }
            r->cursor_shown = d.cursor_shown != 0;
            os_unfair_lock_unlock(&r->screen_lock);
            r->on_screen = d.on_screen;
            if (d.on_screen) [r present:d.on_screen];
            [r drawCursor];
        }
    });
    fprintf(stderr, "hengevm: pvg-metal: screen %llu and a %ux%u pointer restored\n", (unsigned long long)d.on_screen, d.cursor_w, d.cursor_h);
}
