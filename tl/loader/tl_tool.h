/* Part of tl_loader.c: tools run again and again in one process (tl_load_tool, tl_tool_run). A compiler or linker
   expects a fresh process: it registers its options once and frees little. Before each run its writable data is put
   back as it was before its initializers, which then run again; its heap is a zone of its own, destroyed afterwards;
   what it left mapped or open is let go. */
#include <malloc/malloc.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/uio.h>

typedef struct TlToolExit { void (*fn)(void *); void *arg; } TlToolExit;
typedef struct TlToolMap { void *at; size_t len; } TlToolMap;

static pthread_mutex_t g_tool_run_lock = PTHREAD_MUTEX_INITIALIZER; /* one run at a time */
static pthread_mutex_t g_tool_lock = PTHREAD_MUTEX_INITIALIZER;     /* what follows */
static pthread_cond_t g_tool_cond = PTHREAD_COND_INITIALIZER;
static struct {
    TlImage *exe;
    malloc_zone_t *zone;
    pthread_t thread;
    int argc, code, ended, stuck;
    const char **argv, **env; /* env: variables of its own, over the app's */
    void *entry; /* called instead of the program's main */
    _Atomic int stop;   /* the program has ended: its other threads end at their next wait */
    _Atomic int kill;   /* it is to end: its main thread too */
    _Atomic int live;   /* threads it started that still run */
    void (*output)(void *, const char *, size_t);
    void *context;
    TlToolExit *exits;
    size_t nexits, capexits;
    TlToolMap *maps;
    size_t nmaps, capmaps;
    unsigned char fds[1024];
    pthread_key_t keys[128];
    int nkeys;
} g_tool;

/* Each section of the image's writable data that a run may change. Objective-C's and Swift's own stay: their
   runtimes keep pointers into them. */
static void tool_each_section(TlImage *im, void (^f)(uint8_t *addr, size_t size, int zero)) {
    each_section(im, ^(const struct section_64 *sect, uint8_t *addr) {
        uint32_t type = sect->flags & SECTION_TYPE;
        if (!sect->size || strncmp(sect->segname, "__DATA", 6) || !strncmp(sect->segname, "__DATA_CONST", 12)) return;
        if (!strncmp(sect->sectname, "__objc_", 7) || !strncmp(sect->sectname, "__swift", 7)) return;
        if (type == S_THREAD_LOCAL_REGULAR || type == S_THREAD_LOCAL_ZEROFILL || type == S_THREAD_LOCAL_VARIABLES) return;
        if (type == S_MOD_INIT_FUNC_POINTERS || type == S_INIT_FUNC_OFFSETS) return;
        f(addr, (size_t)sect->size, type == S_ZEROFILL || type == S_GB_ZEROFILL);
    });
}

static void tool_snapshot(TlImage *im) {
    if (im->fresh) return;
    __block size_t total = 1;
    tool_each_section(im, ^(uint8_t *addr, size_t size, int zero) { if (!zero) total += size; });
    uint8_t *copy = malloc(total);
    if (!copy) return;
    __block size_t at = 0;
    tool_each_section(im, ^(uint8_t *addr, size_t size, int zero) {
        if (zero) return;
        memcpy(copy + at, addr, size);
        at += size;
    });
    im->fresh = copy;
}

static void tool_restore(TlImage *im) {
    uint8_t *copy = im->fresh;
    if (!copy) return;
    __block size_t at = 0;
    tool_each_section(im, ^(uint8_t *addr, size_t size, int zero) {
        if (zero) { memset(addr, 0, size); return; }
        memcpy(addr, copy + at, size);
        at += size;
    });
    im->initialized = im->visiting = 0;
    /* Threads that outlive the run (dispatch's) start again with new thread-local variables. */
    if (im->tlv_size) {
        pthread_key_t key;
        if (!pthread_key_create(&key, free)) {
            pthread_key_t old = im->tlv_key;
            im->tlv_key = key;
            each_section(im, ^(const struct section_64 *sect, uint8_t *addr) {
                if ((sect->flags & SECTION_TYPE) != S_THREAD_LOCAL_VARIABLES) return;
                for (uint64_t k = 0; k < sect->size / sizeof(TlvDesc); k++) ((TlvDesc *)addr)[k].key = key;
            });
            pthread_key_delete(old);
        }
    }
}

/* ---- what a tool calls ---- */

static void *tool_malloc(size_t n) { return malloc_zone_malloc(g_tool.zone, n); }
static void *tool_calloc(size_t a, size_t b) { return malloc_zone_calloc(g_tool.zone, a, b); }
static void *tool_realloc(void *p, size_t n) { return p ? realloc(p, n) : tool_malloc(n); }
static void *tool_valloc(size_t n) { return malloc_zone_valloc(g_tool.zone, n); }
static void *tool_aligned(size_t a, size_t n) { return malloc_zone_memalign(g_tool.zone, a < 8 ? 8 : a, n ? n : 1); }
static int tool_posix_memalign(void **out, size_t a, size_t n) {
    void *p = tool_aligned(a, n);
    if (!p) return ENOMEM;
    *out = p;
    return 0;
}
static char *tool_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = tool_malloc(n);
    return p ? memcpy(p, s, n) : NULL;
}
static char *tool_strndup(const char *s, size_t max) {
    size_t n = strnlen(s, max);
    char *p = tool_malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, s, n);
    p[n] = 0;
    return p;
}
static void *tool_new(size_t n) {
    void *p = tool_malloc(n ? n : 1);
    if (!p) abort();
    return p;
}
static void *tool_new_nothrow(size_t n, const void *t) { (void)t; return tool_malloc(n ? n : 1); }
static void *tool_new_aligned(size_t n, size_t a) {
    void *p = tool_aligned(a, n);
    if (!p) abort();
    return p;
}
static void *tool_new_aligned_nothrow(size_t n, size_t a, const void *t) { (void)t; return tool_aligned(a, n); }

static int tool_cxa_atexit(void (*fn)(void *), void *arg, void *dso) {
    (void)dso;
    pthread_mutex_lock(&g_tool_lock);
    if (g_tool.nexits == g_tool.capexits) {
        size_t cap = g_tool.capexits ? g_tool.capexits * 2 : 256;
        TlToolExit *e = realloc(g_tool.exits, cap * sizeof *e);
        if (e) g_tool.exits = e, g_tool.capexits = cap;
    }
    if (g_tool.nexits < g_tool.capexits) g_tool.exits[g_tool.nexits++] = (TlToolExit){fn, arg};
    pthread_mutex_unlock(&g_tool_lock);
    return 0;
}
static void tool_call_plain(void *fn) { ((void (*)(void))fn)(); }
static int tool_atexit(void (*fn)(void)) { return tool_cxa_atexit(tool_call_plain, (void *)fn, NULL); }
static void tool_tlv_atexit(void (*fn)(void *), void *arg) { (void)fn; (void)arg; } /* its memory goes with the zone */
static int tool_zero(void) { return 0; }
static void *tool_null(void) { return NULL; }

static void tool_done(int code, int stuck) {
    pthread_mutex_lock(&g_tool_lock);
    if (!g_tool.ended) g_tool.ended = 1, g_tool.code = code, g_tool.stuck = stuck;
    pthread_cond_broadcast(&g_tool_cond);
    pthread_mutex_unlock(&g_tool_lock);
}
static void tool_run_exits(void) {
    for (;;) {
        pthread_mutex_lock(&g_tool_lock);
        TlToolExit e = {0};
        if (g_tool.nexits) e = g_tool.exits[--g_tool.nexits];
        pthread_mutex_unlock(&g_tool_lock);
        if (!e.fn) return;
        e.fn(e.arg);
    }
}
static void tool__exit(int code) {
    if (pthread_equal(pthread_self(), g_tool.thread)) {
        g_tool.code = code;
        pthread_exit(NULL);
    }
    tool_done(code, 1);
    for (;;) pause();
}
static void tool_exit(int code) {
    if (pthread_equal(pthread_self(), g_tool.thread)) tool_run_exits();
    tool__exit(code);
}
static void tool_abort(void) {
    static const char why[] = "the tool aborted\n";
    if (g_tool.output) g_tool.output(g_tool.context, why, sizeof why - 1);
    tool__exit(134);
}

/* Where a thread of the program waits, it ends when it is time to. */
static void tool__exit(int code);
static void tool_point(void) {
    int main = pthread_equal(pthread_self(), g_tool.thread);
    if (main && g_tool.kill && !g_tool.stop) tool__exit(137);
    if (!main && (g_tool.stop || g_tool.kill)) pthread_exit(NULL);
}
typedef struct TlToolStart { void *(*fn)(void *); void *arg; } TlToolStart;
static void tool_thread_gone(void *x) { (void)x; g_tool.live--; }
static void *tool_thread_start(void *x) {
    TlToolStart t = *(TlToolStart *)x;
    free(x);
    void *r;
    pthread_cleanup_push(tool_thread_gone, NULL);
    r = t.fn(t.arg);
    pthread_cleanup_pop(1);
    return r;
}
static int tool_pthread_create(pthread_t *out, const pthread_attr_t *a, void *(*fn)(void *), void *arg) {
    TlToolStart *t = malloc(sizeof *t);
    if (!t) return EAGAIN;
    *t = (TlToolStart){fn, arg};
    g_tool.live++;
    int rc = pthread_create(out, a, tool_thread_start, t);
    if (rc) { g_tool.live--; free(t); }
    return rc;
}
static int tool_nanosleep(const struct timespec *t, struct timespec *left) {
    tool_point();
    struct timespec now = *t;
    const struct timespec step = {0, 200000000};
    while (now.tv_sec > 0 || now.tv_nsec > step.tv_nsec) {
        nanosleep(&step, NULL);
        tool_point();
        now.tv_nsec -= step.tv_nsec;
        if (now.tv_nsec < 0) now.tv_sec--, now.tv_nsec += 1000000000;
        if (now.tv_sec < 0) return 0;
    }
    int rc = nanosleep(&now, left);
    tool_point();
    return rc;
}
static int tool_usleep(useconds_t us) { return tool_nanosleep(&(struct timespec){us / 1000000, (long)(us % 1000000) * 1000}, NULL); }
static void tool_sleep_for(const int64_t *ns) {
    if (*ns > 0) tool_nanosleep(&(struct timespec){*ns / 1000000000, (long)(*ns % 1000000000)}, NULL);
    else tool_point();
}
/* A wait without end returns now and then, as POSIX allows one to; the program waits again. */
static int tool_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) {
    const struct timespec step = {0, 200000000};
    int rc = pthread_cond_timedwait_relative_np(c, m, &step);
    if (g_tool.stop || g_tool.kill) {
        pthread_mutex_unlock(m);
        tool_point();
        pthread_mutex_lock(m);
    }
    return rc == ETIMEDOUT ? 0 : rc;
}
static void tool_cv_wait(pthread_cond_t *c, pthread_mutex_t **lock) { tool_cond_wait(c, *lock); }
static int tool_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *t) {
    if (!g_tool.stop && !g_tool.kill) return pthread_cond_timedwait(c, m, t);
    pthread_mutex_unlock(m);
    tool_point();
    pthread_mutex_lock(m);
    return ETIMEDOUT;
}
static int tool_cond_timedwait_rel(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *t) {
    if (!g_tool.stop && !g_tool.kill) return pthread_cond_timedwait_relative_np(c, m, t);
    pthread_mutex_unlock(m);
    tool_point();
    pthread_mutex_lock(m);
    return ETIMEDOUT;
}
static uint64_t tool_absolute_time(void) { tool_point(); return mach_absolute_time(); }
static int tool_clock_gettime(clockid_t id, struct timespec *t) { tool_point(); return clock_gettime(id, t); }
static uint64_t tool_steady_now(void) { tool_point(); return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int tool_readable(int fd) {
    for (;;) {
        tool_point();
        struct pollfd p = {fd, POLLIN, 0};
        int n = poll(&p, 1, 200);
        if (n > 0 || (n < 0 && errno != EINTR)) return 1;
        int fl = fcntl(fd, F_GETFL);
        if (fl >= 0 && fl & O_NONBLOCK) return 1;
    }
}
static int tool_accept(int fd, struct sockaddr *a, socklen_t *n) {
    tool_readable(fd);
    int c = accept(fd, a, n);
    if (c >= 0 && c < 1024) g_tool.fds[c] = 1;
    return c;
}
static ssize_t tool_recv(int fd, void *p, size_t n, int flags) {
    if (!(flags & MSG_DONTWAIT)) tool_readable(fd);
    return recv(fd, p, n, flags);
}
static int tool_socket(int d, int t, int p) {
    int fd = socket(d, t, p);
    if (fd >= 0 && fd < 1024) g_tool.fds[fd] = 1;
    return fd;
}
static int tool_select(int n, fd_set *r, fd_set *w, fd_set *e, struct timeval *t) {
    tool_point();
    int rc = select(n, r, w, e, t);
    tool_point();
    return rc;
}

static int tool_is_out(FILE *f) { return f == stdout || f == stderr; }
static void tool_text(const void *p, size_t n) {
    static pthread_mutex_t one = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&one);
    if (g_tool.output && n) g_tool.output(g_tool.context, p, n);
    pthread_mutex_unlock(&one);
}
static ssize_t tool_write(int fd, const void *p, size_t n) {
    if (fd != 1 && fd != 2) return write(fd, p, n);
    tool_text(p, n);
    return (ssize_t)n;
}
static ssize_t tool_writev(int fd, const struct iovec *v, int n) {
    if (fd != 1 && fd != 2) return writev(fd, v, n);
    ssize_t all = 0;
    for (int i = 0; i < n; i++) tool_text(v[i].iov_base, v[i].iov_len), all += (ssize_t)v[i].iov_len;
    return all;
}
static size_t tool_fwrite(const void *p, size_t s, size_t n, FILE *f) {
    if (!tool_is_out(f)) return fwrite(p, s, n, f);
    tool_text(p, s * n);
    return n;
}
static int tool_fputs(const char *p, FILE *f) {
    if (!tool_is_out(f)) return fputs(p, f);
    tool_text(p, strlen(p));
    return 0;
}
static int tool_fputc(int c, FILE *f) {
    if (!tool_is_out(f)) return fputc(c, f);
    char b = (char)c;
    tool_text(&b, 1);
    return (unsigned char)c;
}
static int tool_putchar(int c) { return tool_fputc(c, stdout); }
static int tool_puts(const char *p) { tool_text(p, strlen(p)); tool_text("\n", 1); return 0; }
static int tool_vfprintf(FILE *f, const char *fmt, va_list ap) {
    if (!tool_is_out(f)) return vfprintf(f, fmt, ap);
    char *b = NULL;
    int n = vasprintf(&b, fmt, ap);
    if (n > 0) tool_text(b, (size_t)n);
    free(b);
    return n;
}
static int tool_vprintf(const char *fmt, va_list ap) { return tool_vfprintf(stdout, fmt, ap); }
static int tool_fprintf(FILE *f, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = tool_vfprintf(f, fmt, ap);
    va_end(ap);
    return n;
}
static int tool_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = tool_vfprintf(stdout, fmt, ap);
    va_end(ap);
    return n;
}

static void tool_keep_map(void *at, size_t len) {
    pthread_mutex_lock(&g_tool_lock);
    if (g_tool.nmaps == g_tool.capmaps) {
        size_t cap = g_tool.capmaps ? g_tool.capmaps * 2 : 1024;
        TlToolMap *m = realloc(g_tool.maps, cap * sizeof *m);
        if (m) g_tool.maps = m, g_tool.capmaps = cap;
    }
    if (g_tool.nmaps < g_tool.capmaps) g_tool.maps[g_tool.nmaps++] = (TlToolMap){at, len};
    pthread_mutex_unlock(&g_tool_lock);
}
/* A whole mapping let go is forgotten; part of one stays listed only for what is left of it. */
static void tool_forget_map(void *at, size_t len) {
    len = (len + TL_PAGE - 1) & ~(TL_PAGE - 1);
    uint8_t *a = at, *b = a + len;
    pthread_mutex_lock(&g_tool_lock);
    for (size_t i = 0; i < g_tool.nmaps; i++) {
        uint8_t *m = g_tool.maps[i].at, *e = m + g_tool.maps[i].len;
        if (b <= m || a >= e) continue;
        if (a <= m && b >= e) g_tool.maps[i--] = g_tool.maps[--g_tool.nmaps];
        else if (a <= m) g_tool.maps[i] = (TlToolMap){b, (size_t)(e - b)};
        else g_tool.maps[i].len = (size_t)(a - m); /* a hole: what follows it is left mapped */
    }
    pthread_mutex_unlock(&g_tool_lock);
}
static void *tool_mmap(void *at, size_t len, int prot, int flags, int fd, off_t off) {
    void *p = mmap(at, len, prot, flags, fd, off);
    if (p != MAP_FAILED) tool_keep_map(p, (len + TL_PAGE - 1) & ~(TL_PAGE - 1));
    return p;
}
static int tool_munmap(void *at, size_t len) {
    tool_forget_map(at, len);
    return munmap(at, len);
}
static kern_return_t tool_vm_allocate(vm_map_t task, vm_address_t *at, vm_size_t len, int flags) {
    kern_return_t kr = vm_allocate(task, at, len, flags);
    if (!kr) tool_keep_map((void *)*at, (len + TL_PAGE - 1) & ~(TL_PAGE - 1));
    return kr;
}
static kern_return_t tool_vm_deallocate(vm_map_t task, vm_address_t at, vm_size_t len) {
    tool_forget_map((void *)at, len);
    return vm_deallocate(task, at, len);
}
static int tool_open(const char *path, int flags, ...) {
    va_list ap;
    va_start(ap, flags);
    int mode = flags & O_CREAT ? va_arg(ap, int) : 0;
    va_end(ap);
    int fd = open(path, flags, mode);
    if (fd >= 0 && fd < 1024) g_tool.fds[fd] = 1;
    return fd;
}
static int tool_close(int fd) {
    if (fd >= 0 && fd <= 2) return 0;
    if (fd >= 0 && fd < 1024) g_tool.fds[fd] = 0;
    return close(fd);
}
static int tool_key_create(pthread_key_t *key, void (*dtor)(void *)) {
    (void)dtor;
    int rc = pthread_key_create(key, NULL);
    pthread_mutex_lock(&g_tool_lock);
    if (!rc && g_tool.nkeys < 128) g_tool.keys[g_tool.nkeys++] = *key;
    pthread_mutex_unlock(&g_tool_lock);
    return rc;
}

static char *tool_getenv(const char *name) {
    for (int i = 0; g_tool.env && g_tool.env[i]; i++) {
        size_t n = strlen(name);
        if (!strncmp(g_tool.env[i], name, n) && g_tool.env[i][n] == '=') return (char *)g_tool.env[i] + n + 1;
    }
    return getenv(name);
}

static void *tool_lookup(const char *sym) {
    static const struct { const char *name; void *fn; } table[] = {
        {"_malloc", (void *)tool_malloc}, {"_calloc", (void *)tool_calloc}, {"_realloc", (void *)tool_realloc},
        {"_reallocf", (void *)tool_realloc}, {"_valloc", (void *)tool_valloc}, {"_aligned_alloc", (void *)tool_aligned},
        {"_posix_memalign", (void *)tool_posix_memalign}, {"_strdup", (void *)tool_strdup}, {"_strndup", (void *)tool_strndup},
        {"__Znwm", (void *)tool_new}, {"__Znam", (void *)tool_new},
        {"__ZnwmRKSt9nothrow_t", (void *)tool_new_nothrow}, {"__ZnamRKSt9nothrow_t", (void *)tool_new_nothrow},
        {"__ZnwmSt11align_val_t", (void *)tool_new_aligned}, {"__ZnamSt11align_val_t", (void *)tool_new_aligned},
        {"__ZnwmSt11align_val_tRKSt9nothrow_t", (void *)tool_new_aligned_nothrow},
        {"__ZnamSt11align_val_tRKSt9nothrow_t", (void *)tool_new_aligned_nothrow},
        {"___cxa_atexit", (void *)tool_cxa_atexit}, {"_atexit", (void *)tool_atexit}, {"__tlv_atexit", (void *)tool_tlv_atexit},
        {"_exit", (void *)tool_exit}, {"__exit", (void *)tool__exit}, {"__Exit", (void *)tool__exit}, {"_abort", (void *)tool_abort},
        /* The app's own signal handling and folder are not a tool's to change. */
        {"_sigaction", (void *)tool_zero}, {"_signal", (void *)tool_null}, {"_sigaltstack", (void *)tool_zero},
        {"_chdir", (void *)tool_zero}, {"_dup2", (void *)tool_zero}, {"_setrlimit", (void *)tool_zero}, {"_setitimer", (void *)tool_zero},
        {"_write", (void *)tool_write}, {"_write$NOCANCEL", (void *)tool_write}, {"_writev", (void *)tool_writev},
        {"_fwrite", (void *)tool_fwrite}, {"_fputs", (void *)tool_fputs}, {"_fputc", (void *)tool_fputc}, {"_putc", (void *)tool_fputc},
        {"_putchar", (void *)tool_putchar}, {"_puts", (void *)tool_puts}, {"_printf", (void *)tool_printf},
        {"_fprintf", (void *)tool_fprintf}, {"_vfprintf", (void *)tool_vfprintf}, {"_vprintf", (void *)tool_vprintf},
        {"_mmap", (void *)tool_mmap}, {"_munmap", (void *)tool_munmap}, {"_vm_allocate", (void *)tool_vm_allocate},
        {"_vm_deallocate", (void *)tool_vm_deallocate}, {"_open", (void *)tool_open}, {"_close", (void *)tool_close},
        {"_getenv", (void *)tool_getenv}, {"_pthread_create", (void *)tool_pthread_create}, {"_nanosleep", (void *)tool_nanosleep},
        {"_usleep", (void *)tool_usleep}, {"_pthread_cond_wait", (void *)tool_cond_wait},
        {"_pthread_cond_timedwait", (void *)tool_cond_timedwait}, {"_pthread_cond_timedwait_relative_np", (void *)tool_cond_timedwait_rel},
        {"__ZNSt3__111this_thread9sleep_forERKNS_6chrono8durationIxNS_5ratioILl1ELl1000000000EEEEE", (void *)tool_sleep_for},
        {"__ZNSt3__118condition_variable4waitERNS_11unique_lockINS_5mutexEEE", (void *)tool_cv_wait},
        {"__ZNSt3__16chrono12steady_clock3nowEv", (void *)tool_steady_now}, {"_mach_absolute_time", (void *)tool_absolute_time},
        {"_clock_gettime", (void *)tool_clock_gettime}, {"_accept", (void *)tool_accept}, {"_recv", (void *)tool_recv},
        {"_socket", (void *)tool_socket}, {"_select", (void *)tool_select}, {"_select$DARWIN_EXTSN", (void *)tool_select},
         {"_setvbuf", (void *)tool_zero}, {"_pthread_key_create", (void *)tool_key_create},
    };
    for (size_t i = 0; i < sizeof table / sizeof *table; i++)
        if (!strcmp(sym, table[i].name)) return table[i].fn;
    return NULL;
}

/* ---- running one ---- */

TlImage *tl_load_tool(const char *path, char *err, size_t errlen) {
    if (!g_host) { set_err(err, errlen, "nothing loaded yet"); return NULL; }
    char *argv[] = {(char *)path, NULL};
    TlProc *p = proc_new(0, argv, environ);
    if (!p) { set_err(err, errlen, "too many programs"); return NULL; }
    g_is_tool[p->ns] = 1;
    p->exe = load_library_in(path, p->ns, err, errlen);
    if (!p->exe) { g_procs[p->ns] = NULL; return NULL; }
    return p->exe;
}

static void tool_thread_end(void *x) { (void)x; tool_done(g_tool.code, 0); }
static void *tool_thread(void *x) {
    (void)x;
    pthread_setname_np("tool");
    pthread_cleanup_push(tool_thread_end, NULL);
    run_initializers(g_tool.exe);
    g_tool.code = g_tool.entry ? ((int (*)(int, const char **))g_tool.entry)(g_tool.argc, g_tool.argv)
                               : tl_run_main(g_tool.exe, g_tool.argc, g_tool.argv, (const char **)environ);
    tool_run_exits();
    pthread_cleanup_pop(1);
    return NULL;
}

int tl_tool_run(TlImage *tool, int argc, const char **argv, void (*output)(void *, const char *, size_t), void *context) {
    return tl_tool_run_at(tool, NULL, argc, argv, NULL, output, context);
}

/* A program that is built again and again, such as a game without its window: each build takes the place of the one
   before it. Its Objective-C classes are not registered. replacing: the build before it, ended and no longer used. */
TlImage *tl_load_replaceable(const char *path, TlImage *replacing, char *err, size_t errlen) {
    if (!g_host) { set_err(err, errlen, "nothing loaded yet"); return NULL; }
    int ns = 0;
    pthread_mutex_lock(&g_tool_run_lock);
    if (replacing) {
        ns = replacing->ns;
        if (g_is_tool[ns] == 2) {
            set_err(err, errlen, "the build before it still has threads running: start Henge again");
            pthread_mutex_unlock(&g_tool_run_lock);
            return NULL;
        }
        pthread_mutex_lock(&g_lock);
        TlImage *list = NULL;
        for (TlImage **at = &g_images; *at;) {
            TlImage *im = *at;
            if (im->ns != ns) { at = &im->next; continue; }
            *at = im->next;
            im->next = list, list = im;
        }
        g_ns_main[ns] = NULL;
        pthread_mutex_unlock(&g_lock);
        for (TlImage *im = list; im; im = im->next) { /* stays in g_order, matching nothing */
            im->vmsize = 0;
            im->ns = -1;
            if (im->tlv_size) pthread_key_delete(im->tlv_key), im->tlv_key = (pthread_key_t)-1;
            free(im->fresh);
            im->fresh = NULL;
            munmap(im->map, im->maplen);
            close(im->fd);
        }
        g_procs[ns]->exe = NULL;
    } else {
        char *argv[] = {(char *)path, NULL};
        TlProc *p = proc_new(0, argv, environ);
        if (p) ns = p->ns, g_is_tool[ns] = 1, g_no_objc[ns] = 1;
    }
    TlImage *im = NULL;
    if (!ns) set_err(err, errlen, "too many programs");
    else im = g_procs[ns]->exe = load_library_in(path, ns, err, errlen);
    pthread_mutex_unlock(&g_tool_run_lock);
    return im;
}

void tl_tool_stop(void) { g_tool.kill = 1; }

int tl_tool_run_at(TlImage *tool, const char *entry, int argc, const char **argv, const char **env,
                   void (*output)(void *, const char *, size_t), void *context) {
    pthread_mutex_lock(&g_tool_run_lock);
    int ns = tool->ns;
    if (!g_is_tool[ns] || g_is_tool[ns] == 2) { /* 2: stuck */
        pthread_mutex_unlock(&g_tool_run_lock);
        return TL_TOOL_STUCK;
    }
    memset(&g_tool, 0, sizeof g_tool);
    g_tool.exe = tool, g_tool.argc = argc, g_tool.argv = argv, g_tool.output = output, g_tool.context = context;
    g_tool.env = env;
    if (entry) {
        g_tool.entry = tl_image_local_symbol(tool, entry, NULL);
        if (!g_tool.entry) {
            pthread_mutex_unlock(&g_tool_run_lock);
            return 127;
        }
    }
    g_tool.zone = malloc_create_zone(0, 0);
    for (TlImage *im = g_images; im; im = im->next)
        if (im->ns == ns) tool_restore(im);
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, 64 << 20);
    pthread_mutex_lock(&g_tool_lock);
    int rc = pthread_create(&g_tool.thread, &a, tool_thread, NULL);
    while (!rc && !g_tool.ended) pthread_cond_wait(&g_tool_cond, &g_tool_lock);
    pthread_mutex_unlock(&g_tool_lock);
    pthread_attr_destroy(&a);
    int code = rc ? 127 : g_tool.code & 0xFF;
    g_tool.stop = 1;
    for (int i = 0; i < 300 && g_tool.live > 0; i++) usleep(10000);
    if (!g_tool.stuck && g_tool.live > 0) {
        tl_log("%d of its threads still run", g_tool.live);
        g_tool.stuck = 1;
    }
    if (g_tool.stuck) {
        g_is_tool[ns] = 2; /* its threads still hold its heap: all of it stays */
        pthread_detach(g_tool.thread);
        tl_log("a tool ended from another of its threads (%d): this copy of it is not used again", code);
    } else {
        if (!rc) pthread_join(g_tool.thread, NULL);
        for (size_t i = 0; i < g_tool.nmaps; i++) munmap(g_tool.maps[i].at, g_tool.maps[i].len);
        for (int fd = 3; fd < 1024; fd++)
            if (g_tool.fds[fd]) close(fd);
        for (int i = 0; i < g_tool.nkeys; i++) pthread_key_delete(g_tool.keys[i]);
        malloc_destroy_zone(g_tool.zone);
    }
    free(g_tool.maps);
    free(g_tool.exits);
    g_tool.maps = NULL, g_tool.exits = NULL, g_tool.nmaps = g_tool.nexits = g_tool.capmaps = g_tool.capexits = 0;
    pthread_mutex_unlock(&g_tool_run_lock);
    return code;
}
