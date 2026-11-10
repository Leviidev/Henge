/* Opt-in CGL software compatibility for applications that insist on hardware.
 * Try the unmodified request first. Never report software as accelerated, and
 * preserve profile, buffering, sample count and color/depth requirements.
 * This is a CGL selection policy, not an accelerated OpenGL implementation.
 */
#include <OpenGL/OpenGL.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <stdatomic.h>

static bool enabled;
static _Atomic unsigned messages;

__attribute__((constructor)) static void henge_cgl_loaded(void) {
    const char *value=getenv("HENGE_CGL_SOFTWARE_FALLBACK");
    enabled=value && !strcmp(value,"1");
    fprintf(stderr,"henge-cgl: compatibility library loaded; fallback=%d\n",enabled);
}

static CGLError henge_cgl_choose(const CGLPixelFormatAttribute *attrs,CGLPixelFormatObj *pixel,GLint *count) {
    CGLError original=CGLChoosePixelFormat(attrs,pixel,count);
    if(!enabled || original==kCGLNoError || !attrs || !pixel || !count)return original;
    if(original!=kCGLBadPixelFormat && original!=kCGLBadMatch)return original;
    CGLPixelFormatAttribute retry[128];unsigned out=0;bool changed=false,terminated=false;
    for(unsigned i=0;i<126;) {
        CGLPixelFormatAttribute key=attrs[i++];
        if(!key){terminated=true;break;}
        bool value=false;
        switch(key) {
        case kCGLPFAColorSize:case kCGLPFAAlphaSize:case kCGLPFADepthSize:
        case kCGLPFAStencilSize:case kCGLPFASampleBuffers:case kCGLPFASamples:
        case kCGLPFARendererID:case kCGLPFADisplayMask:case kCGLPFAOpenGLProfile:
        case kCGLPFAVirtualScreenCount:case kCGLPFAAuxBuffers:case kCGLPFAAccumSize:
            value=true;break;
        case kCGLPFAAccelerated:case kCGLPFANoRecovery:case kCGLPFASupportsAutomaticGraphicsSwitching:
            changed=true;continue;
        case kCGLPFAAllRenderers:case kCGLPFATripleBuffer:case kCGLPFADoubleBuffer:
        case kCGLPFAMinimumPolicy:case kCGLPFAMaximumPolicy:case kCGLPFAColorFloat:
        case kCGLPFAMultisample:case kCGLPFASupersample:case kCGLPFASampleAlpha:
        case kCGLPFAClosestPolicy:case kCGLPFABackingStore:case kCGLPFABackingVolatile:
        case kCGLPFAAllowOfflineRenderers:case kCGLPFAAuxDepthStencil:
        case kCGLPFAStereo:case kCGLPFAOffScreen:case kCGLPFAWindow:
        case kCGLPFACompliant:case kCGLPFAPBuffer:case kCGLPFARemotePBuffer:
        case kCGLPFASingleRenderer:case kCGLPFARobust:case kCGLPFAMPSafe:
        case kCGLPFAMultiScreen:case kCGLPFAFullScreen:
            break;
        default:return original; // Unknown requests cannot safely be relaxed.
        }
        retry[out++]=key;
        if(value)retry[out++]=attrs[i++];
    }
    if(!changed || !terminated)return original;
    retry[out]=0;CGLPixelFormatObj replacement=NULL;GLint replacementCount=0;
    CGLError result=CGLChoosePixelFormat(retry,&replacement,&replacementCount);
    if(atomic_fetch_add(&messages,1)<16)
        fprintf(stderr,"henge-cgl: choose fallback original=%d retry=%d formats=%d\n",original,result,replacementCount);
    if(result==kCGLNoError && replacement){*pixel=replacement;*count=replacementCount;return result;}
    if(replacement)CGLReleasePixelFormat(replacement);
    return original;
}

__attribute__((used,section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } hook={
    (const void *)henge_cgl_choose,(const void *)CGLChoosePixelFormat
};
