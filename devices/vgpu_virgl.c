// SPDX-License-Identifier: GPL-2.0-or-later
/* virgl 3D for virtio-gpu: see vgpu_virgl.h. */
#include "vgpu_virgl.h"

#include <stdlib.h>

#ifndef HV_VIRGL

HvVgpuVirgl *hv_vgpu_virgl_create(HvVgpu3d *gl, int gles) {
    (void)gl, (void)gles;
    return NULL;
}
void hv_vgpu_virgl_bind(HvVgpuVirgl *v, HvVirtioGpu *g) { (void)v, (void)g; }
void hv_vgpu_virgl_destroy(HvVgpuVirgl *v) { (void)v; }

#else

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h>
#include <time.h>
#include <virglrenderer.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>

/* ANGLE's platform (EGL_ANGLE_platform_angle, _metal), in case the headers are Mesa's. */
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif

#ifdef HV_VIRGL_DLOPEN
/* In the app the libraries are optional frameworks (ios/scripts/build-gpu-deps.sh), loaded when the Linux
   machine starts: without them, or if they do not load, its GPU is 2D only and the app is unchanged. */
#include <dlfcn.h>
#define VIRGL_FNS(X)                                                                                              \
    X(virgl_renderer_init) X(virgl_renderer_poll) X(virgl_renderer_cleanup) X(virgl_set_log_callback)               \
    X(virgl_renderer_get_cap_set) X(virgl_renderer_fill_caps) X(virgl_renderer_context_create)                      \
    X(virgl_renderer_context_create_with_flags) X(virgl_renderer_context_destroy) X(virgl_renderer_ctx_attach_resource) \
    X(virgl_renderer_ctx_detach_resource) X(virgl_renderer_resource_create) X(virgl_renderer_resource_unref)          \
    X(virgl_renderer_resource_attach_iov) X(virgl_renderer_resource_detach_iov) X(virgl_renderer_transfer_write_iov)  \
    X(virgl_renderer_transfer_read_iov) X(virgl_renderer_submit_cmd) X(virgl_renderer_create_fence)                  \
    X(virgl_renderer_resource_get_info)
#define EGL_FNS(X)                                                                                                \
    X(eglGetProcAddress) X(eglInitialize) X(eglBindAPI) X(eglChooseConfig) X(eglCreateContext) X(eglMakeCurrent)    \
    X(eglGetError) X(eglQueryString) X(eglDestroyContext) X(eglTerminate) X(eglGetCurrentContext)
#define DECLARE(f) static __typeof__(&f) p_##f;
static void (*p_glFinish)(void);
static int (*p_get_info_ext)(int, struct virgl_renderer_resource_info_ext *);
VIRGL_FNS(DECLARE)
EGL_FNS(DECLARE)

static int load_libraries(void) {
    static int loaded; /* 1 loaded, -1 not there */
    if (loaded) return loaded > 0 ? 0 : -1;
    loaded = -1;
    void *egl = dlopen("@rpath/EGL.framework/EGL", RTLD_NOW | RTLD_GLOBAL);
    void *vr = egl ? dlopen("@rpath/virglrenderer.framework/virglrenderer", RTLD_NOW | RTLD_LOCAL) : NULL;
    if (!vr) {
        fprintf(stderr, "virgl: the GPU libraries are not in the app (%s): 2D only\n", dlerror());
        return -1;
    }
#define LOAD(lib, f)                                                                  \
    if (!(p_##f = (__typeof__(p_##f))dlsym(lib, #f))) {                              \
        fprintf(stderr, "virgl: %s is missing from the GPU libraries\n", #f);         \
        return -1;                                                                    \
    }
#define LOAD_VIRGL(f) LOAD(vr, f)
#define LOAD_EGL(f) LOAD(egl, f)
    VIRGL_FNS(LOAD_VIRGL)
    EGL_FNS(LOAD_EGL)
    /* For showing scanouts as their own Metal textures (optional: without them the screen is read back). */
    void *gles = dlopen("@rpath/GLESv2.framework/GLESv2", RTLD_NOW | RTLD_LOCAL);
    p_glFinish = gles ? (void (*)(void))dlsym(gles, "glFinish") : NULL;
    p_get_info_ext = (int (*)(int, struct virgl_renderer_resource_info_ext *))dlsym(vr, "virgl_renderer_resource_get_info_ext");
    loaded = 1;
    return 0;
}
#define virgl_renderer_init p_virgl_renderer_init
#define virgl_renderer_poll p_virgl_renderer_poll
#define virgl_renderer_cleanup p_virgl_renderer_cleanup
#define virgl_set_log_callback p_virgl_set_log_callback
#define virgl_renderer_get_cap_set p_virgl_renderer_get_cap_set
#define virgl_renderer_fill_caps p_virgl_renderer_fill_caps
#define virgl_renderer_context_create p_virgl_renderer_context_create
#define virgl_renderer_context_create_with_flags p_virgl_renderer_context_create_with_flags
#define virgl_renderer_context_destroy p_virgl_renderer_context_destroy
#define virgl_renderer_ctx_attach_resource p_virgl_renderer_ctx_attach_resource
#define virgl_renderer_ctx_detach_resource p_virgl_renderer_ctx_detach_resource
#define virgl_renderer_resource_create p_virgl_renderer_resource_create
#define virgl_renderer_resource_unref p_virgl_renderer_resource_unref
#define virgl_renderer_resource_attach_iov p_virgl_renderer_resource_attach_iov
#define virgl_renderer_resource_detach_iov p_virgl_renderer_resource_detach_iov
#define virgl_renderer_transfer_write_iov p_virgl_renderer_transfer_write_iov
#define virgl_renderer_transfer_read_iov p_virgl_renderer_transfer_read_iov
#define virgl_renderer_submit_cmd p_virgl_renderer_submit_cmd
#define virgl_renderer_create_fence p_virgl_renderer_create_fence
#define virgl_renderer_resource_get_info p_virgl_renderer_resource_get_info
#define eglGetProcAddress p_eglGetProcAddress
#define eglInitialize p_eglInitialize
#define eglBindAPI p_eglBindAPI
#define eglChooseConfig p_eglChooseConfig
#define eglCreateContext p_eglCreateContext
#define eglMakeCurrent p_eglMakeCurrent
#define eglGetError p_eglGetError
#define eglQueryString p_eglQueryString
#define eglDestroyContext p_eglDestroyContext
#define eglTerminate p_eglTerminate
#define eglGetCurrentContext p_eglGetCurrentContext
#else
static int load_libraries(void) { return 0; }
#endif
#include <dlfcn.h>

/* libepoxy (inside virglrenderer) opens EGL and OpenGL ES by these names when a GLES context is current, and abort()s
   the process if it cannot (seen: "Couldn't open libGLESv2.so.2" on a host without it). Open them the same way first:
   a library it would not find then means a 2D GPU, not the app gone. */
static int epoxy_finds_gles(void) {
#ifdef __APPLE__
    static const char *const names[] = {"EGL.framework/EGL", "GLESv2.framework/GLESv2"}; /* how UTM's libepoxy names ANGLE */
#else
    static const char *const names[] = {"libEGL.so.1", "libGLESv2.so.2"};
#endif
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (!dlopen(names[i], RTLD_LAZY | RTLD_LOCAL)) {
            fprintf(stderr, "virgl: %s does not open as libepoxy opens it (%s): no 3D\n", names[i], dlerror());
            return 0;
        }
    return 1;
}

/* virglrenderer only declares it: x, y, z, w, h, d, as the virtio-gpu box (QEMU passes that the same way). */
struct virgl_box {
    uint32_t x, y, z, w, h, d;
};

struct HvVgpuVirgl {
    pthread_t thread;
    pthread_mutex_t mu;
    pthread_cond_t wake, done_cv;
    /* Work for the render thread, in order (under mu): calls that answer wait for theirs (call); the guest's command
       buffers, fences and frames to show go on without waiting (post), so its CPU runs while the GPU works. */
    struct Job *head, *tail;
    int queued;
    int async; /* HV_VIRGL_ASYNC: posted work goes on without the guest waiting (else every job waits, as before) */
    int stopping, started, ok, gles;
    HvVirtioGpu *gpu;
    _Atomic uint64_t last_fence; /* the newest fence asked for, all 64 bits */
    _Atomic int fences_out;
    uint8_t *tmp;
    size_t tmp_cap;
    int log;
    /* Our own EGL (ANGLE on Apple devices, where virglrenderer cannot make a display of its own; or Mesa's
       surfaceless platform on Linux with HV_VIRGL_OWN_EGL, to try the same path): contexts without surfaces. */
    int own_egl;
    EGLDisplay dpy;
    EGLConfig config;
    EGLContext main_ctx;
};

/* --- the render thread --- */

typedef struct Job {
    void (*fn)(HvVgpuVirgl *, void *);
    void *arg;
    int async, done;
    struct Job *next;
} Job;
#define MAX_QUEUED 256 /* posted jobs waiting: a guest that gets this far ahead waits for the GPU */

static void write_fence(void *cookie, uint32_t fence) {
    HvVgpuVirgl *v = cookie;
    /* virglrenderer keeps 32 bits of the guest's 64-bit fence ids: put the rest back. */
    uint64_t last = atomic_load(&v->last_fence);
    uint64_t full = (last & ~0xffffffffull) | fence;
    if (full > last) full -= 1ull << 32;
    atomic_store(&v->fences_out, full < last); /* more after it still to come */
    if (v->gpu) hv_virtio_gpu_fence_done(v->gpu, 0, 0, full);
}

static void log_cb(enum virgl_log_level_flags level, const char *message, void *user) {
    (void)level, (void)user;
    fprintf(stderr, "virgl: %s", message);
}

/* --- our own EGL: the display, and contexts virglrenderer asks for --- */

static int egl_open(HvVgpuVirgl *v) {
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_display = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
#ifdef HV_VIRGL_ANGLE
    /* ANGLE on Metal. */
    static const EGLint attrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
    v->dpy = get_display ? get_display(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, attrs) : EGL_NO_DISPLAY;
#else
    v->dpy = get_display ? get_display(EGL_PLATFORM_SURFACELESS_MESA, (void *)EGL_DEFAULT_DISPLAY, NULL) : EGL_NO_DISPLAY;
#endif
    EGLint major = 0, minor = 0;
    if (v->dpy == EGL_NO_DISPLAY || !eglInitialize(v->dpy, &major, &minor)) {
        fprintf(stderr, "virgl: no EGL display (%#x)\n", eglGetError());
        return -1;
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API)) return -1;
    static const EGLint cfg[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                                 EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLint n = 0;
    if (!eglChooseConfig(v->dpy, cfg, &v->config, 1, &n) || n < 1) {
        static const EGLint any[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE};
        if (!eglChooseConfig(v->dpy, any, &v->config, 1, &n) || n < 1) return -1;
    }
    static const EGLint ctx_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
    v->main_ctx = eglCreateContext(v->dpy, v->config, EGL_NO_CONTEXT, ctx_attrs);
    if (v->main_ctx == EGL_NO_CONTEXT || !eglMakeCurrent(v->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, v->main_ctx)) {
        fprintf(stderr, "virgl: no EGL context (%#x)\n", eglGetError());
        return -1;
    }
    fprintf(stderr, "virgl: EGL %d.%d, %s, %s\n", major, minor, eglQueryString(v->dpy, EGL_VENDOR), eglQueryString(v->dpy, EGL_VERSION));
    return 0;
}

static virgl_renderer_gl_context egl_create(void *cookie, int scanout, struct virgl_renderer_gl_ctx_param *p) {
    (void)scanout;
    HvVgpuVirgl *v = cookie;
    EGLint attrs[] = {EGL_CONTEXT_MAJOR_VERSION, p->major_ver ? p->major_ver : 3, EGL_CONTEXT_MINOR_VERSION, p->minor_ver, EGL_NONE};
    /* "Shared" means with the context current now, as virglrenderer's own EGL and QEMU's do: virglrenderer makes its
       context 0 unshared and then the guest's contexts while it is current, so all of them see the same textures.
       (Sharing with a context of our own instead put the guest's drawing where context 0, which reads the screen
       back, could not see it: a black screen.) */
    EGLContext share = EGL_NO_CONTEXT;
    if (p->shared) {
        share = eglGetCurrentContext();
        if (share == EGL_NO_CONTEXT) share = v->main_ctx;
    }
    EGLContext c = eglCreateContext(v->dpy, v->config, share, attrs);
    if (c == EGL_NO_CONTEXT && v->log) fprintf(stderr, "virgl: context %d.%d refused (%#x)\n", p->major_ver, p->minor_ver, eglGetError());
    return c == EGL_NO_CONTEXT ? NULL : (virgl_renderer_gl_context)c;
}

static void egl_destroy(void *cookie, virgl_renderer_gl_context c) {
    eglDestroyContext(((HvVgpuVirgl *)cookie)->dpy, (EGLContext)c);
}

static int egl_make_current(void *cookie, int scanout, virgl_renderer_gl_context c) {
    (void)scanout;
    HvVgpuVirgl *v = cookie;
    return eglMakeCurrent(v->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, c ? (EGLContext)c : v->main_ctx) ? 0 : -1;
}

static void *egl_display(void *cookie) { return ((HvVgpuVirgl *)cookie)->dpy; }

static void *render_thread(void *arg) {
    HvVgpuVirgl *v = arg;
    static struct virgl_renderer_callbacks cbs = {.version = 1, .write_fence = write_fence};
    int flags = VIRGL_RENDERER_USE_EGL | VIRGL_RENDERER_USE_SURFACELESS | (v->gles ? VIRGL_RENDERER_USE_GLES : 0);
    if (v->log) virgl_set_log_callback(log_cb, NULL, NULL);
    int r = 0;
    if (v->own_egl) {
        /* The contexts are ours (QEMU's way in UTM), GLES: what ANGLE has. */
        cbs.version = 4;
        cbs.create_gl_context = egl_create;
        cbs.destroy_gl_context = egl_destroy;
        cbs.make_current = egl_make_current;
        cbs.get_egl_display = egl_display;
        flags = VIRGL_RENDERER_USE_GLES;
#if defined(HV_VIRGL_ANGLE) && defined(HV_VIRGL_DLOPEN)
        if (!getenv("HV_VIRGL_NO_NATIVE")) flags |= VIRGL_RENDERER_NATIVE_SHARE_TEXTURE; /* scanouts as Metal textures */
#endif
        r = egl_open(v);
    }
    if (r == 0) r = virgl_renderer_init(v, flags, &cbs);
    pthread_mutex_lock(&v->mu);
    v->ok = r == 0;
    v->started = 1;
    pthread_cond_broadcast(&v->done_cv);
    if (r != 0) {
        fprintf(stderr, "virgl: virgl_renderer_init failed (%d)\n", r);
        pthread_mutex_unlock(&v->mu);
        return NULL;
    }
    while (!v->stopping || v->head) {
        if (!v->head) {
            if (v->stopping) break;
            /* Idle: retire fences every millisecond while any are out, else sleep until called. */
            if (atomic_load(&v->fences_out)) {
                struct timespec ts;
                clock_gettime(CLOCK_REALTIME, &ts);
                ts.tv_nsec += 1000000;
                if (ts.tv_nsec >= 1000000000) ts.tv_sec++, ts.tv_nsec -= 1000000000;
                pthread_cond_timedwait(&v->wake, &v->mu, &ts);
            } else {
                pthread_cond_wait(&v->wake, &v->mu);
            }
        }
        while (v->head) {
            Job *j = v->head;
            v->head = j->next;
            if (!v->head) v->tail = NULL;
            if (j->async) v->queued--;
            pthread_mutex_unlock(&v->mu);
            j->fn(v, j->arg);
            if (j->async) {
                free(j->arg);
                free(j);
            }
            pthread_mutex_lock(&v->mu);
            if (!j->async) j->done = 1; /* the caller's own Job: it frees nothing */
            pthread_cond_broadcast(&v->done_cv);
            if (atomic_load(&v->fences_out)) break; /* retire fences between jobs too */
        }
        if (atomic_load(&v->fences_out)) {
            pthread_mutex_unlock(&v->mu);
            virgl_renderer_poll();
            pthread_mutex_lock(&v->mu);
        }
    }
    pthread_mutex_unlock(&v->mu);
    virgl_renderer_cleanup(v);
    if (v->own_egl && v->dpy != EGL_NO_DISPLAY) {
        eglMakeCurrent(v->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (v->main_ctx != EGL_NO_CONTEXT) eglDestroyContext(v->dpy, v->main_ctx);
        eglTerminate(v->dpy);
    }
    return NULL;
}

static void enqueue(HvVgpuVirgl *v, Job *j) {
    j->next = NULL;
    if (v->tail) v->tail->next = j;
    else v->head = j;
    v->tail = j;
    pthread_cond_signal(&v->wake);
}

/* Runs job(arg) on the render thread after everything before it, and waits for it. */
static void call(HvVgpuVirgl *v, void (*job)(HvVgpuVirgl *, void *), void *arg) {
    Job j = {.fn = job, .arg = arg};
    pthread_mutex_lock(&v->mu);
    enqueue(v, &j);
    while (!j.done) pthread_cond_wait(&v->done_cv, &v->mu);
    pthread_mutex_unlock(&v->mu);
}

/* Queues job(arg) without waiting; arg is malloc'd and freed after the job. */
static void post(HvVgpuVirgl *v, void (*job)(HvVgpuVirgl *, void *), void *arg) {
    Job *j = v->async ? calloc(1, sizeof *j) : NULL;
    if (!j) { /* not asked for (or no memory): the guest waits, as it always did */ /* no memory: run it in order the slow way */
        call(v, job, arg);
        free(arg);
        return;
    }
    j->fn = job, j->arg = arg, j->async = 1;
    pthread_mutex_lock(&v->mu);
    while (v->queued >= MAX_QUEUED && !v->stopping) pthread_cond_wait(&v->done_cv, &v->mu);
    v->queued++;
    enqueue(v, j);
    pthread_mutex_unlock(&v->mu);
}

static void j_nothing(HvVgpuVirgl *v, void *a) { (void)v, (void)a; }
/* Waits until everything queued so far has run. */
static void drain(void *o) { call(o, j_nothing, NULL); }

/* --- the renderer interface, each call marshalled to the render thread --- */

typedef struct Args {
    uint32_t u[12];
    uint64_t u64;
    const void *p;
    void *out;
    void **iov_base;
    uint32_t *iov_len;
    int r;
} Args;

static void j_capset_info(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    uint32_t id = a->u[0] + 1; /* capsets 1 (VIRGL) and 2 (VIRGL2) */
    uint32_t ver = 0, size = 0;
    virgl_renderer_get_cap_set(id, &ver, &size);
    a->u[1] = id, a->u[2] = ver, a->u[3] = size;
    a->r = size ? 0 : -1;
}
static int capset_info(void *o, uint32_t index, uint32_t *id, uint32_t *max_version, uint32_t *max_size) {
    Args a = {.u = {index}};
    if (index >= 2) return -1;
    call(o, j_capset_info, &a);
    *id = a.u[1], *max_version = a.u[2], *max_size = a.u[3];
    return a.r;
}

static void j_capset(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    virgl_renderer_fill_caps(a->u[0], a->u[1], a->out);
}
static int capset(void *o, uint32_t id, uint32_t version, void *out, uint32_t size) {
    (void)size;
    Args a = {.u = {id, version}, .out = out};
    call(o, j_capset, &a);
    return 0;
}

static void j_ctx_create(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    a->r = a->u[1] ? virgl_renderer_context_create_with_flags(a->u[0], a->u[1], a->u[2], a->p)
                   : virgl_renderer_context_create(a->u[0], a->u[2], a->p);
}
static int ctx_create(void *o, uint32_t ctx, uint32_t context_init, const char *name, uint32_t name_len) {
    Args a = {.u = {ctx, context_init, name_len}, .p = name};
    call(o, j_ctx_create, &a);
    if (((HvVgpuVirgl *)o)->log) fprintf(stderr, "virgl: context %u (%.*s) -> %d\n", ctx, (int)name_len, name ? name : "", a.r);
    return a.r;
}

static void j_ctx_destroy(HvVgpuVirgl *v, void *a_) {
    (void)v;
    virgl_renderer_context_destroy(((Args *)a_)->u[0]);
}
static void ctx_destroy(void *o, uint32_t ctx) {
    Args a = {.u = {ctx}};
    call(o, j_ctx_destroy, &a);
}

static void j_ctx_attach(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    if (a->u[2]) virgl_renderer_ctx_attach_resource((int)a->u[0], (int)a->u[1]);
    else virgl_renderer_ctx_detach_resource((int)a->u[0], (int)a->u[1]);
}
static void ctx_attach(void *o, uint32_t ctx, uint32_t res) {
    Args a = {.u = {ctx, res, 1}};
    call(o, j_ctx_attach, &a);
}
static void ctx_detach(void *o, uint32_t ctx, uint32_t res) {
    Args a = {.u = {ctx, res, 0}};
    call(o, j_ctx_attach, &a);
}

static void j_create_3d(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    struct virgl_renderer_resource_create_args c = {
        .handle = a->u[0], .target = a->u[1], .format = a->u[2], .bind = a->u[3], .width = a->u[4], .height = a->u[5],
        .depth = a->u[6], .array_size = a->u[7], .last_level = a->u[8], .nr_samples = a->u[9], .flags = a->u[10]};
    a->r = virgl_renderer_resource_create(&c, NULL, 0);
}
static int resource_create_3d(void *o, uint32_t res, const uint32_t args[10]) {
    Args a = {.u = {res}};
    memcpy(a.u + 1, args, 10 * sizeof *args);
    call(o, j_create_3d, &a);
    return a.r;
}

static void j_unref(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    struct iovec *iov = NULL;
    int n = 0;
    virgl_renderer_resource_detach_iov((int)a->u[0], &iov, &n);
    free(iov);
    virgl_renderer_resource_unref(a->u[0]);
}
static void resource_unref(void *o, uint32_t res) {
    Args a = {.u = {res}};
    call(o, j_unref, &a);
}

static void j_attach(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    uint32_t n = a->u[1];
    struct iovec *iov = calloc(n, sizeof *iov); /* virglrenderer keeps it until detached */
    if (!iov) {
        a->r = -ENOMEM;
        return;
    }
    for (uint32_t i = 0; i < n; i++) iov[i].iov_base = a->iov_base[i], iov[i].iov_len = a->iov_len[i];
    a->r = virgl_renderer_resource_attach_iov((int)a->u[0], iov, (int)n);
    if (a->r) free(iov);
}
static int attach_backing(void *o, uint32_t res, void **iov_base, uint32_t *iov_len, uint32_t n) {
    Args a = {.u = {res, n}, .iov_base = iov_base, .iov_len = iov_len};
    call(o, j_attach, &a);
    return a.r;
}

static void j_detach(HvVgpuVirgl *v, void *a_) {
    (void)v;
    struct iovec *iov = NULL;
    int n = 0;
    virgl_renderer_resource_detach_iov((int)((Args *)a_)->u[0], &iov, &n);
    free(iov);
}
static void detach_backing(void *o, uint32_t res) {
    Args a = {.u = {res}};
    call(o, j_detach, &a);
}

static void j_transfer(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    struct virgl_box box;
    memcpy(&box, a->p, sizeof box);
    if (a->u[0])
        a->r = virgl_renderer_transfer_write_iov(a->u[2], a->u[1], (int)a->u[3], a->u[4], a->u[5], &box, a->u64, NULL, 0);
    else
        a->r = virgl_renderer_transfer_read_iov(a->u[2], a->u[1], a->u[3], a->u[4], a->u[5], &box, a->u64, NULL, 0);
}
static int transfer(void *o, int to_host, uint32_t ctx, uint32_t res, const uint32_t box[6], uint32_t level, uint32_t stride,
                    uint32_t layer_stride, uint64_t offset) {
    Args a = {.u = {(uint32_t)to_host, ctx, res, level, stride, layer_stride}, .u64 = offset, .p = box};
    call(o, j_transfer, &a);
    return a.r;
}

/* A command buffer, copied: the guest's CPU goes on while the render thread decodes it. */
typedef struct SubmitArgs {
    uint32_t ctx, size;
    uint8_t cmd[];
} SubmitArgs;
static void j_submit(HvVgpuVirgl *v, void *a_) {
    SubmitArgs *a = a_;
    int r = virgl_renderer_submit_cmd(a->cmd, (int)a->ctx, (int)(a->size / 4));
    static int told;
    if (r && (v->log || told++ < 5)) fprintf(stderr, "virgl: submit %u bytes on context %u -> %d\n", a->size, a->ctx, r);
}
static int submit(void *o, uint32_t ctx, void *cmd, uint32_t size) {
    SubmitArgs *a = malloc(sizeof *a + size);
    if (!a) return -1;
    a->ctx = ctx, a->size = size;
    memcpy(a->cmd, cmd, size);
    post(o, j_submit, a);
    return 0;
}

static void j_fence(HvVgpuVirgl *v, void *a_) {
    Args *a = a_;
    atomic_store(&v->last_fence, a->u64);
    atomic_store(&v->fences_out, 1);
    a->r = virgl_renderer_create_fence((int)(uint32_t)a->u64, a->u[0]);
}
static int create_fence(void *o, uint32_t ctx, uint32_t ring, uint64_t fence) {
    (void)ring;
    Args *a = calloc(1, sizeof *a);
    if (!a) return -1;
    a->u[0] = ctx, a->u64 = fence;
    post(o, j_fence, a); /* in order after the commands it fences; it signals when the GPU gets there */
    return 0;
}

#if defined(HV_VIRGL_ANGLE) && defined(HV_VIRGL_DLOPEN)
#include <CoreFoundation/CoreFoundation.h>
#ifndef VIRGL_RENDERER_NATIVE_SHARE_TEXTURE
#define VIRGL_RENDERER_NATIVE_SHARE_TEXTURE (1 << 12)
#endif
/* A scanout's own Metal texture (UTM's virglrenderer makes scanouts Metal textures that ANGLE draws into, with
   VIRGL_RENDERER_NATIVE_SHARE_TEXTURE), once the GPU has finished what the guest drew: glFinish on the context the
   guest last drew with, which is current here. */
static void j_native(HvVgpuVirgl *v, void *a_) {
    (void)v;
    Args *a = a_;
    a->out = NULL;
    if (!p_get_info_ext || !p_glFinish) return;
    struct virgl_renderer_resource_info_ext ext;
    memset(&ext, 0, sizeof ext);
    ext.version = VIRGL_RENDERER_RESOURCE_INFO_EXT_VERSION;
    if (p_get_info_ext((int)a->u[0], &ext) != 0 || ext.native_type != VIRGL_NATIVE_HANDLE_METAL_TEXTURE || !ext.native_handle) return;
    p_glFinish();
    a->u[1] = (ext.base.flags & 1) != 0; /* VIRGL_RESOURCE_Y_0_TOP */
    a->out = (void *)CFRetain(ext.native_handle);
}
static void *native_texture(void *o, uint32_t res, int *y0top) {
    Args a = {.u = {res}};
    call(o, j_native, &a);
    *y0top = (int)a.u[1];
    return a.out;
}
/* The same, without waiting: once the GPU has finished the frame, show(texture) runs on the render thread. */
typedef struct PresentArgs {
    Args a;
    void (*show)(void *ctx, void *texture, int y0top);
    uint8_t ctx[64];
} PresentArgs;
static void j_present(HvVgpuVirgl *v, void *a_) {
    PresentArgs *p = a_;
    j_native(v, &p->a);
    p->show(p->ctx, p->a.out, (int)p->a.u[1]); /* NULL: no texture */
}
static int present(void *o, uint32_t res, void (*show)(void *ctx, void *texture, int y0top), const void *ctx, size_t ctx_size) {
    PresentArgs *p = calloc(1, sizeof *p);
    if (!p || ctx_size > sizeof p->ctx) {
        free(p);
        return -1;
    }
    p->a.u[0] = res, p->show = show;
    memcpy(p->ctx, ctx, ctx_size);
    post(o, j_present, p);
    return 0;
}
#endif

/* The screen: a rectangle of the scanned-out texture read back, top row first, as BGRA. */
static void j_read(HvVgpuVirgl *v, void *a_) {
    Args *a = a_;
    uint32_t res = a->u[0], x = a->u[1], y = a->u[2], w = a->u[3], h = a->u[4], out_stride = a->u[5];
    /* Only its format: with virglrenderer's own EGL the call also asks EGL for a DRM format and fails where there is
       none (surfaceless), after filling in the rest. */
    struct virgl_renderer_resource_info info;
    memset(&info, 0, sizeof info);
    virgl_renderer_resource_get_info((int)res, &info);
    if (!info.virgl_format) {
        static int told;
        if (v->log || !told++) fprintf(stderr, "virgl: no resource %u to show\n", res);
        a->r = -1;
        return;
    }
    size_t bytes = (size_t)w * h * 4;
    if (bytes > v->tmp_cap) {
        uint8_t *bigger = realloc(v->tmp, bytes);
        if (!bigger) {
            a->r = -1;
            return;
        }
        v->tmp = bigger, v->tmp_cap = bytes;
    }
    struct virgl_box box = {x, y, 0, w, h, 1};
    struct iovec iov = {v->tmp, bytes};
    a->r = virgl_renderer_transfer_read_iov(res, 0, 0, w * 4, (uint32_t)bytes, &box, 0, &iov, 1);
    if (a->r) {
        static int told;
        if (!told++) fprintf(stderr, "virgl: reading resource %u back for the screen failed (%d)\n", res, a->r);
        return;
    }
    uint8_t *out = a->out;
    for (uint32_t row = 0; row < h; row++) hv_vgpu_to_bgra(info.virgl_format, v->tmp + (size_t)row * w * 4, out + (size_t)row * out_stride, w);
}
static int read_pixels(void *o, uint32_t res, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint8_t *out, uint32_t out_stride) {
    Args a = {.u = {res, x, y, w, h, out_stride}, .out = out};
    call(o, j_read, &a);
    return a.r;
}

HvVgpuVirgl *hv_vgpu_virgl_create(HvVgpu3d *gl, int gles) {
    if (load_libraries() != 0) return NULL;
    HvVgpuVirgl *v = calloc(1, sizeof *v);
    if (!v) return NULL;
    v->gles = gles;
    v->log = getenv("HV_VIRGL_LOG") != NULL;
#ifdef HV_VIRGL_ANGLE
    v->own_egl = 1;
#else
    v->own_egl = getenv("HV_VIRGL_OWN_EGL") != NULL;
#endif
    v->dpy = EGL_NO_DISPLAY, v->main_ctx = EGL_NO_CONTEXT;
    if ((v->own_egl || v->gles) && !epoxy_finds_gles()) {
        free(v);
        return NULL;
    }
    pthread_mutex_init(&v->mu, NULL);
    v->async = getenv("HV_VIRGL_ASYNC") != NULL;
    pthread_cond_init(&v->wake, NULL);
    pthread_cond_init(&v->done_cv, NULL);
    if (pthread_create(&v->thread, NULL, render_thread, v) != 0) {
        free(v);
        return NULL;
    }
    pthread_mutex_lock(&v->mu);
    while (!v->started) pthread_cond_wait(&v->done_cv, &v->mu);
    int ok = v->ok;
    pthread_mutex_unlock(&v->mu);
    if (!ok) {
        pthread_join(v->thread, NULL);
        free(v);
        return NULL;
    }
    memset(gl, 0, sizeof *gl);
    gl->opaque = v;
    gl->ncapsets = 2;
    gl->capset_info = capset_info;
    gl->capset = capset;
    gl->ctx_create = ctx_create;
    gl->ctx_destroy = ctx_destroy;
    gl->ctx_attach = ctx_attach;
    gl->ctx_detach = ctx_detach;
    gl->resource_create_3d = resource_create_3d;
    gl->resource_unref = resource_unref;
    gl->attach_backing = attach_backing;
    gl->detach_backing = detach_backing;
    gl->transfer = transfer;
    gl->submit = submit;
    gl->create_fence = create_fence;
    gl->read_pixels = read_pixels;
#if defined(HV_VIRGL_ANGLE) && defined(HV_VIRGL_DLOPEN)
    gl->native_texture = native_texture;
    if (v->async) gl->present = present;
#endif
    gl->drain = drain;
    fprintf(stderr, "virgl: renderer started (%s%s)\n", gles || v->own_egl ? "OpenGL ES" : "OpenGL", v->own_egl ? ", own EGL contexts" : "");
    return v;
}

void hv_vgpu_virgl_bind(HvVgpuVirgl *v, HvVirtioGpu *g) {
    if (v) v->gpu = g;
}

void hv_vgpu_virgl_destroy(HvVgpuVirgl *v) {
    if (!v) return;
    pthread_mutex_lock(&v->mu);
    v->stopping = 1;
    pthread_cond_signal(&v->wake);
    pthread_mutex_unlock(&v->mu);
    pthread_join(v->thread, NULL);
    free(v->tmp);
    free(v);
}

#endif
