/* A command-line Mac program in a terminal, without macOS: its standard input and output are a socket that answers
   as a terminal does (isatty, the window size, raw mode), since an iOS app gets no pseudo-terminal of its own. The
   program runs on a thread of this process, one per launch (henge-tl.c). Other processes it tries to start are
   refused, as iOS does; a web page it opens (/usr/bin/open URL: signing in) is handed to the app. */
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include "henge-ios-jit.h"
#include "henge-tl.h"
#include "henge-vm.h"
#include "../../../tl/loader/tl_loader.h"

HengeDualMapping *henge_ios_jit_get_mapping(void);
void henge_tl_mark_ran(void); /* henge-tl.c: one program or app per launch */
extern _Atomic int henge_tl_ran;

static TlHost host;
static TlImage *image;
static int host_fd = -1;
static struct termios tio;
static struct winsize size = {40, 80, 0, 0};
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static HengeTlTermOutput on_output;
static HengeTlTermOpen on_open;
static HengeTlTermExit on_exit_cb;
static char **g_argv;
static int g_argc;
static pthread_t main_thread;
static _Atomic int ended;

static void finish(int code) {
    if (atomic_exchange(&ended, 1)) return;
    fprintf(stderr, "henge: term: the program ended with %d\n", code);
    if (on_exit_cb) on_exit_cb(code);
}

static int is_term(int fd) { return fd >= 0 && fd <= 2; }
static int term_isatty(int fd) { return is_term(fd) ? 1 : isatty(fd); }
static int term_tcgetattr(int fd, struct termios *t) {
    if (!is_term(fd)) return tcgetattr(fd, t);
    pthread_mutex_lock(&lock);
    *t = tio;
    pthread_mutex_unlock(&lock);
    return 0;
}
static int term_tcsetattr(int fd, int how, const struct termios *t) {
    if (!is_term(fd)) return tcsetattr(fd, how, t);
    pthread_mutex_lock(&lock);
    tio = *t;
    pthread_mutex_unlock(&lock);
    return 0;
}
static int term_ioctl(int fd, unsigned long request, ...) {
    va_list ap;
    va_start(ap, request);
    void *p = va_arg(ap, void *);
    va_end(ap);
    if (is_term(fd)) {
        int known = 1;
        pthread_mutex_lock(&lock);
        switch (request) {
        case TIOCGWINSZ: *(struct winsize *)p = size; break;
        case TIOCGETA: *(struct termios *)p = tio; break;
        case TIOCSETA: case TIOCSETAW: case TIOCSETAF: tio = *(const struct termios *)p; break;
        default: known = 0;
        }
        pthread_mutex_unlock(&lock);
        if (known) return 0;
    }
    return ioctl(fd, request, p);
}
/* The program's exit ends its own thread, not Henge. */
static void term_exit(int code) {
    fflush(NULL);
    finish(code);
    for (;;) {
        if (pthread_equal(pthread_self(), main_thread)) pthread_exit(NULL);
        pause(); /* another of its threads called it: the main one may still be running */
    }
}
/* /usr/bin/security, the Mac's keychain tool, which iOS has not: it runs, finds nothing and can save nothing, so a
   program (Claude Code) keeps its sign-in in its own private file instead. Refusing to start it says only "try again
   later". The "process" has ended when it is returned; the kernel knows no such pid, so a watch on it fails at once
   and the program asks wait4. */
enum { SECURITY_PID = 0x40000000, SECURITY_PIDS = 4096, NOT_FOUND = 44 };
static _Atomic unsigned security_next;
static _Atomic unsigned char security_code[SECURITY_PIDS]; /* 0: no such process; else the exit code + 1 */
static int security_tool(pid_t *pid, const char *path, char *const argv[]) {
    if (!path || !argv || !argv[0]) return 0;
    const char *base = strrchr(path, '/'), *verb = argv[1];
    base = base ? base + 1 : path;
    if (!strcmp(base, "sh") && argv[1] && !strcmp(argv[1], "-c") && argv[2]) {
        const char *cmd = argv[2];
        if (!strncmp(cmd, "/usr/bin/", 9)) cmd += 9;
        if (strncmp(cmd, "security ", 9) || strpbrk(cmd, ";|&\n")) return 0;
        verb = cmd + 9;
    } else if (strcmp(base, "security"))
        return 0;
    int lookup = verb && (!strncmp(verb, "find-", 5) || !strncmp(verb, "delete-", 7));
    unsigned i = atomic_fetch_add(&security_next, 1) % SECURITY_PIDS;
    atomic_store(&security_code[i], (unsigned char)((lookup ? NOT_FOUND : 1) + 1));
    if (pid) *pid = SECURITY_PID + (pid_t)i;
    fprintf(stderr, "henge: term: security %.24s: answered %d (%u)\n", verb ? verb : "", lookup ? NOT_FOUND : 1, i); /* not its arguments: a secret is one */
    return 1;
}
static pid_t term_wait4(pid_t pid, int *status, int options, struct rusage *ru) {
    if (pid >= SECURITY_PID && pid < SECURITY_PID + SECURITY_PIDS) {
        int code = atomic_exchange(&security_code[pid - SECURITY_PID], 0);
        if (!code) return errno = ECHILD, -1;
        if (status) *status = (code - 1) << 8;
        fprintf(stderr, "henge: term: security: told it ended (%d)\n", pid - SECURITY_PID);
        if (code - 1 != NOT_FOUND)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                char file[PATH_MAX];
                struct stat st;
                snprintf(file, sizeof file, "%s/.claude/.credentials.json", getenv("HOME") ? getenv("HOME") : "");
                if (stat(file, &st)) fprintf(stderr, "henge: term: no private sign-in file: %s\n", strerror(errno));
                else fprintf(stderr, "henge: term: private sign-in file: %lld bytes\n", (long long)st.st_size);
            });
        if (ru) memset(ru, 0, sizeof *ru);
        return pid;
    }
    pid_t (*next)(pid_t, int *, int, struct rusage *) = tl_runtime_lookup("_wait4");
    return next ? next(pid, status, options, ru) : wait4(pid, status, options, ru);
}
static pid_t term_waitpid(pid_t pid, int *status, int options) {
    if (pid >= SECURITY_PID && pid < SECURITY_PID + SECURITY_PIDS) return term_wait4(pid, status, options, NULL);
    pid_t (*next)(pid_t, int *, int) = tl_runtime_lookup("_waitpid");
    return next ? next(pid, status, options) : waitpid(pid, status, options);
}
static int term_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *attr,
                      char *const argv[], char *const envp[]) {
    size_t n = path ? strlen(path) : 0;
    if (n >= 4 && !strcmp(path + n - 4, "open") && (n == 4 || path[n - 5] == '/'))
        for (int i = 1; argv && argv[i]; i++)
            if (!strncmp(argv[i], "https://", 8) && on_open) {
                on_open(argv[i]);
                return EPERM; /* there is no such process to wait for: the program shows the address as well */
            }
    if (security_tool(pid, path, argv)) return 0;
    int (*refuse)(pid_t *, const char *, const void *, const void *, char *const[], char *const[]) = tl_runtime_lookup("_posix_spawn");
    return refuse ? refuse(pid, path, fa, attr, argv, envp) : EPERM;
}

/* A program looks for the tool on its PATH (/henge/bin is first there) before it starts it, and iOS has no such file:
   it sees a file that is there, Henge's own. */
#define SECURITY_PATH "/henge/bin/security"
static const char *seen(const char *path) {
    static char own[PATH_MAX];
    if (!path || strcmp(path, SECURITY_PATH)) return path;
    uint32_t n = sizeof own;
    if (!own[0] && _NSGetExecutablePath(own, &n)) own[0] = 0;
    return own[0] ? own : path;
}
static int term_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    const char *p = seen(path);
    if (p != path) return open(p, O_RDONLY | O_CLOEXEC);
    int (*next)(const char *, int, ...) = tl_runtime_lookup("_open");
    return (next ? next : open)(path, flags, mode);
}
static int term_access(const char *path, int mode) {
    const char *p = seen(path);
    int (*next)(const char *, int) = tl_runtime_lookup("_access");
    return (next ? next : access)(p, p == path ? mode : F_OK);
}
static int term_stat(const char *path, struct stat *st) {
    int (*next)(const char *, struct stat *) = tl_runtime_lookup("_stat");
    return (next ? next : stat)(seen(path), st);
}

/* A watch on such a process fails as the kernel's does on one that is gone, whatever this kernel would say. */
static int is_security(uint64_t ident, int16_t filter) {
    return filter == EVFILT_PROC && ident >= SECURITY_PID && ident < SECURITY_PID + SECURITY_PIDS;
}
#define FLAGS_COMMA ,
#define KEVENT(name, type, extra_decl, extra)                                                                              \
    static int term_##name(int kq, const type *ch, int nch, type *ev, int nev, extra_decl const struct timespec *t) {      \
        int mine = 0;                                                                                                      \
        for (int i = 0; i < nch; i++) mine += is_security(ch[i].ident, ch[i].filter);                                      \
        if (!mine) return name(kq, ch, nch, ev, nev, extra t);                                                             \
        fprintf(stderr, "henge: term: security: watched\n");                                                              \
        type *rest = calloc((size_t)nch, sizeof *rest);                                                                    \
        int n = 0, out = 0;                                                                                                \
        for (int i = 0; i < nch; i++)                                                                                      \
            if (!is_security(ch[i].ident, ch[i].filter)) rest[n++] = ch[i];                                                \
            else if (out < nev) ev[out] = ch[i], ev[out].flags = EV_ERROR, ev[out++].data = ESRCH;                         \
        struct timespec now = {0, 0};                                                                                      \
        int rc = n || (out && out < nev) ? name(kq, rest, n, ev + out, nev - out, extra &now) : 0;                         \
        free(rest);                                                                                                        \
        if (rc < 0) return rc;                                                                                             \
        if (!out) return errno = ESRCH, -1;                                                                                \
        return out + rc;                                                                                                   \
    }
KEVENT(kevent, struct kevent, , )
KEVENT(kevent64, struct kevent64_s, unsigned flags FLAGS_COMMA, flags FLAGS_COMMA)

/* The loader answers these itself: asked first. */
static void *first_lookup(const char *symbol) {
    if (!strcmp(symbol, "_posix_spawn") || !strcmp(symbol, "_posix_spawnp")) return (void *)term_spawn;
    if (!strcmp(symbol, "_wait4")) return (void *)term_wait4;
    if (!strcmp(symbol, "_waitpid")) return (void *)term_waitpid;
    if (!strcmp(symbol, "_open")) return (void *)term_open;
    if (!strcmp(symbol, "_access")) return (void *)term_access;
    if (!strcmp(symbol, "_stat")) return (void *)term_stat;
    if (!strcmp(symbol, "_kevent")) return (void *)term_kevent;
    if (!strcmp(symbol, "_kevent64")) return (void *)term_kevent64;
    return NULL;
}

static void *shim_lookup(const char *install_name, const char *symbol) {
    static const struct { const char *name; void *fn; } table[] = {
        {"_isatty", (void *)term_isatty}, {"_tcgetattr", (void *)term_tcgetattr}, {"_tcsetattr", (void *)term_tcsetattr},
        {"_ioctl", (void *)term_ioctl}, {"_exit", (void *)term_exit}, {"__exit", (void *)term_exit}, {"__Exit", (void *)term_exit},
    };
    if (!strstr(install_name, "libSystem")) return NULL;
    for (size_t i = 0; i < sizeof table / sizeof *table; i++)
        if (!strcmp(symbol, table[i].name)) return table[i].fn;
    return tl_runtime_lookup(symbol);
}

static void log_line(const char *line) { fprintf(stderr, "henge: term: %s\n", line); }

static void *read_thread(void *arg) {
    (void)arg;
    pthread_setname_np("terminal output");
    static char buf[65536];
    for (;;) {
        ssize_t n = read(host_fd, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        if (on_output) on_output(buf, (size_t)n);
    }
    return NULL;
}

static void *run_thread(void *arg) {
    (void)arg;
    pthread_setname_np("terminal program");
    extern char **environ;
    int code = tl_run_main(image, g_argc, (const char **)g_argv, (const char **)environ);
    fflush(NULL);
    finish(code);
    return NULL;
}

int henge_tl_term_start(const char *path, const char *const *args, const char *const *env, const char *dir, int cols, int rows,
                        HengeTlTermOutput output, HengeTlTermOpen open_url, HengeTlTermExit ended_cb, char *err, size_t errlen) {
    if (henge_tl_ran_program() || atomic_load(&henge_tl_ran))
        return snprintf(err, errlen, "One program per launch: quit Henge (swipe it away) and open it again to run another."), -1;
    int vm = henge_vm_state();
    if (vm == 1 || vm == 3 || vm == 4) return snprintf(err, errlen, "Stop the Mac first: a program and a Mac cannot run at once."), -1;
    HengeDualMapping *jit = henge_ios_jit_get_mapping();
    if (!jit || !jit->rw_addr || !jit->rx_addr) return snprintf(err, errlen, "Turn on JIT first."), -1;
    if (jit->size < (size_t)500 << 20) return snprintf(err, errlen, "The JIT region is too small (Settings > Performance > Code cache: 1 GB or more)."), -1;
    on_output = output, on_open = open_url, on_exit_cb = ended_cb;
    size.ws_col = (unsigned short)cols, size.ws_row = (unsigned short)rows;
    memset(&tio, 0, sizeof tio);
    cfmakeraw(&tio);
    tio.c_iflag |= ICRNL;
    tio.c_oflag |= OPOST | ONLCR;
    tio.c_lflag |= ECHO | ICANON | ISIG | IEXTEN;
    for (int i = 0; env && env[i]; i++) { /* the program may read the process's own environment */
        char *copy = strdup(env[i]), *eq = strchr(copy, '=');
        if (eq) *eq = 0, setenv(copy, eq + 1, 1);
        free(copy);
    }
    if (dir && chdir(dir)) fprintf(stderr, "henge: term: cannot enter %s: %s\n", dir, strerror(errno));
    signal(SIGPIPE, SIG_IGN);
    memset(&host, 0, sizeof host);
    size_t keep = (size_t)16 << 20; /* the region's start stays QEMU's way of finding it; the rest is the program's */
    tl_host_init_region(&host, jit->rx_addr + keep, jit->rw_addr + keep, jit->size - keep);
    host.map_install_name = tl_ios_map_install_name;
    host.shim_lookup = shim_lookup;
    host.first_lookup = first_lookup;
    host.log = log_line;
    host.soft_missing = 1;
    host.no_processes = 1;
    host.ios_kernel_rules = 1;
    atomic_store(&henge_tl_ran, 1); /* from here the JIT region is the program's: no Mac in this launch */
    henge_tl_mark_ran();
    fprintf(stderr, "henge: term: loading %s\n", path);
    image = tl_load(&host, path, err, errlen);
    if (!image) {
        fprintf(stderr, "henge: term: %s\n", err);
        return -1;
    }
    fprintf(stderr, "henge: term: loaded at %p, %zu MB, %zu MB of the region, %d missing symbols\n", tl_image_base(image),
            tl_image_size(image) >> 20, host.used >> 20, tl_missing_count());
    for (int i = 0; i < tl_missing_count() && i < 20; i++) fprintf(stderr, "henge: term: missing %s\n", tl_missing_name(i));
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) return snprintf(err, errlen, "No terminal: %s", strerror(errno)), -1;
    host_fd = sv[0];
    int on = 1;
    setsockopt(host_fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    fflush(NULL);
    dup2(sv[1], 0); /* standard error stays Henge's log */
    dup2(sv[1], 1);
    close(sv[1]);
    int n = 0;
    while (args && args[n]) n++;
    g_argv = calloc((size_t)n + 2, sizeof *g_argv);
    g_argv[0] = strdup(path);
    for (int i = 0; i < n; i++) g_argv[i + 1] = strdup(args[i]);
    g_argc = n + 1;
    pthread_t reader;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16u << 20);
    int rc = pthread_create(&reader, NULL, read_thread, NULL) || pthread_create(&main_thread, &attr, run_thread, NULL);
    pthread_attr_destroy(&attr);
    if (rc) return snprintf(err, errlen, "No thread for the program."), -1;
    return 0;
}

void henge_tl_term_write(const char *bytes, size_t len) {
    if (host_fd < 0 || atomic_load(&ended)) return;
    pthread_mutex_lock(&lock);
    int canonical = (tio.c_lflag & ICANON) != 0, echo = (tio.c_lflag & ECHO) != 0;
    pthread_mutex_unlock(&lock);
    if (!canonical) {
        // In one go, so a program reads a key's bytes, or a paste, together.
        for (size_t at = 0; at < len;) {
            ssize_t n = write(host_fd, bytes + at, len - at);
            if (n > 0) at += (size_t)n;
            else if (n < 0 && (errno == EINTR || errno == EAGAIN)) usleep(1000);
            else return;
        }
        return;
    }
    for (size_t i = 0; i < len; i++) {
        char c = bytes[i];
        if (c == '\r') c = '\n';
        if (echo && on_output) {
            if (c == '\n') on_output("\r\n", 2);
            else on_output(&c, 1);
        }
        while (write(host_fd, &c, 1) < 0 && (errno == EINTR || errno == EAGAIN)) usleep(1000);
    }
}

void henge_tl_term_resize(int cols, int rows) {
    pthread_mutex_lock(&lock);
    int changed = size.ws_col != cols || size.ws_row != rows;
    size.ws_col = (unsigned short)cols, size.ws_row = (unsigned short)rows;
    pthread_mutex_unlock(&lock);
    if (changed && host_fd >= 0 && !atomic_load(&ended)) kill(getpid(), SIGWINCH);
}

/* The compiler, linker and other tools beside it (tl_tool_command): loaded at their first use and kept. */
static char *tool_folders[9];
void henge_tl_tool_setup(const char *const *folders, int copies) {
    int n = 0;
    for (; folders && folders[n] && n < 8; n++) tool_folders[n] = strdup(folders[n]);
    tool_folders[n] = NULL;
    host.tool_folders = tool_folders, host.tool_copies = copies;
}

int henge_tl_tool_run(const char *path, int argc, const char *const *argv, const char *const *env, const char *cwd,
                      HengeTlToolOutput output, void *context) {
    if (!image) return -1;
    return tl_tool_command(path, argc, (const char **)argv, (const char **)env, cwd, output, context);
}

static TlImage *program;
static pthread_mutex_t program_lock = PTHREAD_MUTEX_INITIALIZER;

int henge_tl_program_run(const char *path, const char *argv0, const char *entry, const char *const *env, HengeTlToolOutput output, void *context) {
    if (!image) return -1;
    char err[512] = "";
    pthread_mutex_lock(&program_lock);
    TlImage *im = tl_load_replaceable(path, program, err, sizeof err);
    if (im) program = im;
    pthread_mutex_unlock(&program_lock);
    if (!im) {
        output(context, err, strlen(err));
        return -1;
    }
    fprintf(stderr, "henge: term: loaded %s, %zu MB of the region in use\n", path, host.used >> 20);
    const char *argv[] = {argv0, NULL};
    return tl_tool_run_at(im, entry, 1, argv, (const char **)env, output, context);
}

void henge_tl_program_stop(void) { if (program) tl_tool_stop(program); }
void henge_tl_tool_stop(const char *cwd) { tl_tool_stop_in(cwd); }
