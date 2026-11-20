// SPDX-License-Identifier: GPL-2.0-or-later
/* The Linux machine's screen on the app's CAMetalLayer: see vgpu_metal.h. */
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vgpu_metal.h"

static NSString *const shaders =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct V { float4 p [[position]]; float2 uv; };\n"
     /* A rectangle (x, y, w, h in clip space, y up) with texture coordinates (u0, v0, u1, v1), v0 its top row. */
     "vertex V rect_vs(uint vid [[vertex_id]], constant float4 &r [[buffer(0)]], constant float4 &t [[buffer(1)]]) {\n"
     "  float2 c = float2(float(vid & 1), float(vid >> 1));\n"
     "  V o; o.p = float4(r.x + c.x * r.z, r.y + (1 - c.y) * r.w, 0, 1);\n"
     "  o.uv = float2(mix(t.x, t.z, c.x), mix(t.y, t.w, c.y)); return o; }\n"
     "fragment float4 screen_fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
     "  return float4(t.sample(s, v.uv).rgb, 1); }\n"
     "fragment float4 pointer_fs(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
     "  return t.sample(s, v.uv); }\n";

@interface HvVgpuMetalImpl : NSObject {
@public
    HvVirtioGpu *gpu;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> screen_pipe, pointer_pipe;
    id<MTLSamplerState> linear, nearest;
    dispatch_queue_t presenter;
    os_unfair_lock lock;
    /* under lock */
    CAMetalLayer *layer;
    __weak CAMetalLayer *prepared;
    uint64_t generation;
    id<MTLTexture> screen2d; /* the 2D screen, BGRA, filled from the device's pixels */
    id<MTLTexture> scanout;  /* or a 3D scanout's own texture */
    BOOL show3d, y0top, dirty, running, stopping;
    uint32_t W, H, sx, sy, tw, th;
    /* presenter queue only */
    id<MTLTexture> pointer_tex;
    uint8_t pointer_px[64 * 64 * 4];
    _Atomic uint64_t frames;
}
@end

@implementation HvVgpuMetalImpl

- (BOOL)setUp {
    device = MTLCreateSystemDefaultDevice();
    if (!device) return NO;
    queue = [device newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:shaders options:nil error:&err];
    if (!lib) {
        fprintf(stderr, "vgpu-metal: shaders: %s\n", err.localizedDescription.UTF8String);
        return NO;
    }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"rect_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"screen_fs"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    screen_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
    d.fragmentFunction = [lib newFunctionWithName:@"pointer_fs"];
    d.colorAttachments[0].blendingEnabled = YES; /* the pointer's image is premultiplied, as DRM's are */
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pointer_pipe = [device newRenderPipelineStateWithDescriptor:d error:&err];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    linear = [device newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    nearest = [device newSamplerStateWithDescriptor:sd];
    MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
    t.usage = MTLTextureUsageShaderRead;
    pointer_tex = [device newTextureWithDescriptor:t];
    if (!screen_pipe || !pointer_pipe || !linear || !nearest || !pointer_tex) {
        fprintf(stderr, "vgpu-metal: pipelines: %s\n", err.localizedDescription.UTF8String);
        return NO;
    }
    presenter = dispatch_queue_create("henge.linux-screen", DISPATCH_QUEUE_SERIAL);
    lock = OS_UNFAIR_LOCK_INIT;
    return YES;
}

/* lock held */
- (void)kick {
    if (running || stopping || !layer) return;
    running = YES;
    dispatch_async(presenter, ^{ [self presentLoop]; });
}

- (void)presentLoop {
    for (;;) @autoreleasepool {
        os_unfair_lock_lock(&lock);
        if (!dirty || !layer || stopping) {
            running = NO;
            os_unfair_lock_unlock(&lock);
            return;
        }
        dirty = NO;
        CAMetalLayer *target = layer;
        uint64_t gen = generation;
        id<MTLTexture> tex = show3d ? scanout : screen2d;
        BOOL flip = show3d && y0top;
        uint32_t w = W, h = H, x0 = show3d ? sx : 0, y0 = show3d ? sy : 0, twidth = show3d ? tw : W, theight = show3d ? th : H;
        os_unfair_lock_unlock(&lock);
        if (!tex || !w || !h) continue;

        if (prepared != target) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            target.device = device;
            target.pixelFormat = MTLPixelFormatBGRA8Unorm;
            target.framebufferOnly = YES;
            target.allowsNextDrawableTimeout = YES;
            target.maximumDrawableCount = 3;
            [CATransaction commit];
            prepared = target;
        }
        if (target.drawableSize.width != w || target.drawableSize.height != h) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            target.drawableSize = CGSizeMake(w, h);
            [CATransaction commit];
        }
        /* The pointer, as the guest last set it. */
        uint32_t hx = 0, hy = 0;
        int32_t px = 0, py = 0;
        int pointer_on = hv_virtio_gpu_cursor(gpu, pointer_px, &hx, &hy, &px, &py);
        if (pointer_on) [pointer_tex replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:pointer_px bytesPerRow:64 * 4];

        id<CAMetalDrawable> drawable = [target nextDrawable]; /* the wait is here, on this queue */
        if (!drawable) { /* none in time: try again shortly */
            os_unfair_lock_lock(&lock);
            dirty = YES;
            running = NO;
            os_unfair_lock_unlock(&lock);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), presenter, ^{
                os_unfair_lock_lock(&self->lock);
                [self kick];
                os_unfair_lock_unlock(&self->lock);
            });
            return;
        }
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
        float r[4] = {-1, -1, 2, 2};
        float u0 = (float)x0 / twidth, u1 = (float)(x0 + w) / twidth;
        float v0 = (float)y0 / theight, v1 = (float)(y0 + h) / theight;
        float t[4] = {u0, flip ? 1 - v0 : v0, u1, flip ? 1 - v1 : v1};
        [e setRenderPipelineState:screen_pipe];
        [e setVertexBytes:r length:sizeof r atIndex:0];
        [e setVertexBytes:t length:sizeof t atIndex:1];
        [e setFragmentTexture:tex atIndex:0];
        [e setFragmentSamplerState:linear atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        if (pointer_on) {
            float cx = (float)(px - (int32_t)hx), cy = (float)(py - (int32_t)hy);
            float pr[4] = {cx / w * 2 - 1, 1 - (cy + 64) / h * 2, 64.0f / w * 2, 64.0f / h * 2};
            float pt[4] = {0, 0, 1, 1};
            [e setRenderPipelineState:pointer_pipe];
            [e setVertexBytes:pr length:sizeof pr atIndex:0];
            [e setVertexBytes:pt length:sizeof pt atIndex:1];
            [e setFragmentTexture:pointer_tex atIndex:0];
            [e setFragmentSamplerState:nearest atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [e endEncoding];
        os_unfair_lock_lock(&lock);
        if (generation == gen && layer == target && !stopping) {
            [cb presentDrawable:drawable];
            [cb commit];
            atomic_fetch_add(&frames, 1);
        } else {
            dirty = YES;
        }
        os_unfair_lock_unlock(&lock);
    }
}

@end

/* --- the device's presenter: screen locked, a guest CPU's thread; no blocking --- */

static void on_pixels(void *opaque, const HvVgpuScreen *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    HvVgpuMetalImpl *m = (__bridge HvVgpuMetalImpl *)opaque;
    if (!s->pixels || !s->width || !s->height) return;
    os_unfair_lock_lock(&m->lock);
    if (!m->screen2d || m->screen2d.width != s->width || m->screen2d.height != s->height) {
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:s->width height:s->height mipmapped:NO];
        t.usage = MTLTextureUsageShaderRead;
        m->screen2d = [m->device newTextureWithDescriptor:t];
        x = 0, y = 0, w = s->width, h = s->height; /* a new texture: all of it */
    }
    if (w && h && m->screen2d)
        [m->screen2d replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:0
                         withBytes:s->pixels + ((size_t)y * s->width + x) * 4 bytesPerRow:(NSUInteger)s->width * 4];
    m->show3d = NO;
    m->scanout = nil;
    m->W = s->width, m->H = s->height;
    m->dirty = YES;
    [m kick];
    os_unfair_lock_unlock(&m->lock);
}

static void on_texture(void *opaque, void *texture, uint32_t width, uint32_t height, uint32_t sx, uint32_t sy, uint32_t sw, uint32_t sh,
                       int y0top) {
    HvVgpuMetalImpl *m = (__bridge HvVgpuMetalImpl *)opaque;
    id<MTLTexture> tex = (__bridge_transfer id<MTLTexture>)texture; /* the device handed us its reference */
    os_unfair_lock_lock(&m->lock);
    m->scanout = tex;
    m->show3d = YES;
    m->y0top = y0top != 0;
    m->tw = width, m->th = height, m->sx = sx, m->sy = sy, m->W = sw, m->H = sh;
    m->dirty = YES;
    [m kick];
    os_unfair_lock_unlock(&m->lock);
}

static void on_cursor(void *opaque) {
    HvVgpuMetalImpl *m = (__bridge HvVgpuMetalImpl *)opaque;
    os_unfair_lock_lock(&m->lock);
    if (m->screen2d || m->scanout) {
        m->dirty = YES;
        [m kick];
    }
    os_unfair_lock_unlock(&m->lock);
}

HvVgpuMetal *hv_vgpu_metal_create(HvVirtioGpu *gpu) {
    if (!gpu) return NULL;
    HvVgpuMetalImpl *m = [HvVgpuMetalImpl new];
    m->gpu = gpu;
    if (![m setUp]) return NULL;
    HvVgpuPresenter p = {.opaque = (__bridge void *)m, .pixels = on_pixels, .texture = on_texture, .cursor = on_cursor};
    hv_virtio_gpu_set_presenter(gpu, &p);
    fprintf(stderr, "vgpu-metal: the Linux screen is drawn by the GPU (%s)\n", m->device.name.UTF8String);
    return (HvVgpuMetal *)(void *)CFBridgingRetain(m);
}

void hv_vgpu_metal_set_layer(HvVgpuMetal *p, void *layer) {
    if (!p) return;
    HvVgpuMetalImpl *m = (__bridge HvVgpuMetalImpl *)(void *)p;
    os_unfair_lock_lock(&m->lock);
    m->layer = (__bridge CAMetalLayer *)layer;
    m->generation++;
    if (m->screen2d || m->scanout) {
        m->dirty = YES; /* the newest frame on the new layer at once */
        [m kick];
    }
    os_unfair_lock_unlock(&m->lock);
}

uint64_t hv_vgpu_metal_frames(HvVgpuMetal *p) {
    return p ? atomic_load(&((__bridge HvVgpuMetalImpl *)(void *)p)->frames) : 0;
}

void hv_vgpu_metal_destroy(HvVgpuMetal *p) {
    if (!p) return;
    HvVgpuMetalImpl *m = (__bridge HvVgpuMetalImpl *)(void *)p;
    hv_virtio_gpu_set_presenter(m->gpu, NULL);
    os_unfair_lock_lock(&m->lock);
    m->stopping = YES;
    m->layer = nil;
    os_unfair_lock_unlock(&m->lock);
    dispatch_sync(m->presenter, ^{}); /* a frame being drawn finishes (it reads the device's pointer) */
    CFBridgingRelease((CFTypeRef)p);
}
