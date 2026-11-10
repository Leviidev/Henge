#ifndef HENGE_PVG_VIEWPORT_REPLAY_H
#define HENGE_PVG_VIEWPORT_REPLAY_H

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <string.h>

/* Only the successful pipeline's actual vertex function can authorize this
   flag. The caller obtains it from validated shader-profile provenance. */
static char hv_pvg_pipeline_gl_clip_key;
static inline void hv_pvg_pipeline_set_gl_clip(id pipeline, BOOL enabled) {
    if (pipeline) objc_setAssociatedObject(pipeline, &hv_pvg_pipeline_gl_clip_key,
                                           @(enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static inline BOOL hv_pvg_pipeline_gl_clip(id pipeline) {
    return [objc_getAssociatedObject(pipeline, &hv_pvg_pipeline_gl_clip_key) boolValue];
}

/* Worker-owned, one current render encoder. Keep the original wire values:
   converting an already converted viewport would accumulate depth changes. */
@interface HvPvgViewportReplay : NSObject {
@public
    NSData *raw;
    BOOL array;
    BOOL gl_clip;
}
@end
@implementation HvPvgViewportReplay
@end

static inline void hv_pvg_viewport_reset(HvPvgViewportReplay *state) {
    state->raw = nil;
    state->array = NO;
    state->gl_clip = NO;
}

static inline BOOL hv_pvg_viewport_apply(HvPvgViewportReplay *state,
                                        id<MTLRenderCommandEncoder> encoder) {
    if (!state->raw.length || !encoder) return NO; /* unknown raw viewport */
    NSData *values = state->raw;
    if (state->gl_clip) {
        NSMutableData *converted = [values mutableCopy];
        MTLViewport *viewports = converted.mutableBytes;
        NSUInteger count = converted.length / sizeof(*viewports);
        for (NSUInteger i = 0; i < count; i++) {
            /* The GL producer already mapped rawNear=(near+far)/2. Pair
               z'=(z+w)/2 in the verified vertex shader with the true near.
               Preserve reversed ranges; do not sort or clamp either end. */
            viewports[i].znear = 2 * viewports[i].znear - viewports[i].zfar;
        }
        values = converted;
    }
    if (state->array) {
        [encoder setViewports:values.bytes count:values.length / sizeof(MTLViewport)];
    } else {
        MTLViewport viewport;
        memcpy(&viewport, values.bytes, sizeof viewport);
        [encoder setViewport:viewport];
    }
    return YES;
}

static inline BOOL hv_pvg_viewport_record(HvPvgViewportReplay *state,
                                         id<MTLRenderCommandEncoder> encoder,
                                         const void *bytes, NSUInteger count,
                                         BOOL array) {
    if (!bytes || !count || count > NSUIntegerMax / sizeof(MTLViewport) || (!array && count != 1)) return NO;
    state->raw = [NSData dataWithBytes:bytes length:count * sizeof(MTLViewport)];
    state->array = array;
    return hv_pvg_viewport_apply(state, encoder);
}

static inline BOOL hv_pvg_viewport_pipeline(HvPvgViewportReplay *state,
                                           id<MTLRenderCommandEncoder> encoder,
                                           id pipeline) {
    state->gl_clip = hv_pvg_pipeline_gl_clip(pipeline);
    return hv_pvg_viewport_apply(state, encoder);
}
#endif
