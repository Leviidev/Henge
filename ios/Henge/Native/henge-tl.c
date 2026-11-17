/* Mac apps without macOS (experimental): importing, describing and running them through the translation layer. */
#include "henge-tl.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <TargetConditionals.h>
#include <unistd.h>

#include "henge-ios-jit.h"
#include "henge-vm.h"
#include "../../../tl/dmg/tl_dmg.h"
#include "../../../tl/loader/tl_loader.h"

HengeDualMapping *henge_ios_jit_get_mapping(void);
extern _Atomic int henge_tl_ran; /* henge-vm.c: no Mac starts once this is set */

int henge_tl_used(void) { return atomic_load(&henge_tl_ran); }

static int is_macho(uint32_t magic) {
    return magic == MH_MAGIC_64 || magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
}

int henge_tl_import_dmg(const char *dmg, const char *dir, char *err, size_t errlen) {
    TlDisk *disk = tl_disk_open(dmg, err, errlen);
    if (!disk) return -1;
    TlVolume *vol = tl_volume_open(disk, err, errlen);
    if (!vol) {
        tl_disk_close(disk);
        return -1;
    }
    TlNode root;
    if (tl_volume_lookup(vol, "/", &root) != 0) {
        snprintf(err, errlen, "The disk image's volume has no top folder.");
        tl_volume_close(vol), tl_disk_close(disk);
        return -1;
    }
    /* What to copy: names first, as copying while listing would walk the catalog twice at once. */
    __block char **names = NULL;
    __block int count = 0;
    tl_volume_list(vol, &root, ^int(const char *name, const TlNode *node) {
        if (name[0] == '.') return 0;
        size_t len = strlen(name);
        int app = S_ISDIR(node->mode) && len > 4 && !strcasecmp(name + len - 4, ".app");
        int program = 0;
        if (S_ISREG(node->mode) && node->size >= 4) {
            uint32_t magic = 0;
            if (tl_volume_read(vol, node, 0, &magic, 4) == 4) program = is_macho(magic);
        }
        if (!app && !program) return 0;
        char **more = realloc(names, sizeof *names * (size_t)(count + 1));
        if (!more) return 1;
        names = more;
        names[count++] = strdup(name);
        return 0;
    });
    int copied = 0;
    for (int i = 0; i < count; i++) {
        char from[1100], to[2048];
        snprintf(from, sizeof from, "/%s", names[i]);
        snprintf(to, sizeof to, "%s/%s", dir, names[i]);
        char why[512] = "";
        if (tl_volume_extract(vol, from, to, why, sizeof why) == 0) copied++;
        else snprintf(err, errlen, "Could not copy %s: %s", names[i], why);
        free(names[i]);
    }
    free(names);
    tl_volume_close(vol);
    tl_disk_close(disk);
    if (!copied && count) return -1;
    if (!count) snprintf(err, errlen, "The disk image holds no app or program at its top level.");
    return copied;
}

/* The arm64 slice's load commands: which libraries it links and what platform it was built for. */
static void scan_slice(int fd, uint64_t off, HengeTlInfo *info, int *appkit, int *swiftui, int *catalyst) {
    struct mach_header_64 mh;
    if (pread(fd, &mh, sizeof mh, (off_t)off) != sizeof mh || mh.magic != MH_MAGIC_64 || mh.sizeofcmds > (1u << 24)) return;
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds || pread(fd, cmds, mh.sizeofcmds, (off_t)(off + sizeof mh)) != (ssize_t)mh.sizeofcmds) {
        free(cmds);
        return;
    }
    for (uint32_t i = 0, at = 0; i < mh.ncmds && at + sizeof(struct load_command) <= mh.sizeofcmds; i++) {
        const struct load_command *lc = (const void *)(cmds + at);
        if (!lc->cmdsize || at + lc->cmdsize > mh.sizeofcmds) break;
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB || lc->cmd == LC_REEXPORT_DYLIB ||
            lc->cmd == LC_LAZY_LOAD_DYLIB || lc->cmd == LC_LOAD_UPWARD_DYLIB) {
            const struct dylib_command *d = (const void *)lc;
            if (d->dylib.name.offset < lc->cmdsize) {
                const char *name = (const char *)lc + d->dylib.name.offset;
                size_t room = lc->cmdsize - d->dylib.name.offset;
                if (memchr(name, 0, room)) {
                    info->libraries++;
                    if (strstr(name, "/AppKit.framework/") || strstr(name, "/Cocoa.framework/")) *appkit = 1;
                    if (strstr(name, "/SwiftUI.framework/")) *swiftui = 1;
                    if (strstr(name, "/System/iOSSupport/") || strstr(name, "/UIKit.framework/")) *catalyst = 1;
                }
            }
        } else if (lc->cmd == LC_BUILD_VERSION && ((const struct build_version_command *)lc)->platform == PLATFORM_MACCATALYST) {
            *catalyst = 1;
        }
        at += lc->cmdsize;
    }
    free(cmds);
}

/* One Mach-O file's arm64 code (the whole file, or its slice of a universal one): see scan_slice. */
static void scan_file(const char *path, HengeTlInfo *info, int *appkit, int *swiftui, int *catalyst) {
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        uint32_t magic = 0;
        if (pread(fd, &magic, 4, 0) == 4) {
            if (magic == MH_MAGIC_64) scan_slice(fd, 0, info, appkit, swiftui, catalyst);
            else if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) { /* universal: big-endian table */
                struct fat_header fh;
                if (pread(fd, &fh, sizeof fh, 0) == sizeof fh) {
                    uint32_t n = OSSwapBigToHostInt32(fh.nfat_arch);
                    int wide = magic == FAT_CIGAM_64;
                    for (uint32_t i = 0; i < n && i < 16; i++) {
                        uint64_t off = 0;
                        int32_t cpu = 0;
                        if (wide) {
                            struct fat_arch_64 a;
                            if (pread(fd, &a, sizeof a, (off_t)(sizeof fh + i * sizeof a)) != sizeof a) break;
                            cpu = (int32_t)OSSwapBigToHostInt32((uint32_t)a.cputype), off = OSSwapBigToHostInt64(a.offset);
                        } else {
                            struct fat_arch a;
                            if (pread(fd, &a, sizeof a, (off_t)(sizeof fh + i * sizeof a)) != sizeof a) break;
                            cpu = (int32_t)OSSwapBigToHostInt32((uint32_t)a.cputype), off = OSSwapBigToHostInt32(a.offset);
                        }
                        if (cpu == CPU_TYPE_ARM64) {
                            scan_slice(fd, off, info, appkit, swiftui, catalyst);
                            break;
                        }
                    }
                }
            }
        }
        close(fd);
    }
}

/* An app's own frameworks and libraries (Contents/Frameworks): a Chromium or Electron app's program links only
   libSystem and loads its framework, which is where AppKit shows. */
static void scan_frameworks(const char *app, int *appkit, int *swiftui, int *catalyst) {
    char dir[1100];
    snprintf(dir, sizeof dir, "%s/Contents/Frameworks", app);
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t n = strlen(e->d_name);
        char bin[2400];
        HengeTlInfo scratch;
        memset(&scratch, 0, sizeof scratch);
        if (n > 10 && !strcmp(e->d_name + n - 10, ".framework")) {
            snprintf(bin, sizeof bin, "%s/%s/%.*s", dir, e->d_name, (int)(n - 10), e->d_name);
            struct stat st;
            if (stat(bin, &st) != 0) snprintf(bin, sizeof bin, "%s/%s/Versions/Current/%.*s", dir, e->d_name, (int)(n - 10), e->d_name);
        } else if (n > 6 && !strcmp(e->d_name + n - 6, ".dylib")) {
            snprintf(bin, sizeof bin, "%s/%s", dir, e->d_name);
        } else continue;
        scan_file(bin, &scratch, appkit, swiftui, catalyst);
    }
    closedir(d);
}

int henge_tl_info(const char *path, HengeTlInfo *info, char *err, size_t errlen) {
    memset(info, 0, sizeof *info);
    TlAppInfo ai;
    if (tl_app_info(path, &ai, err, errlen) != 0) return -1;
    struct stat st;
    if (stat(path, &st) != 0) return snprintf(err, errlen, "%s", strerror(errno)), -1;
    if (S_ISDIR(st.st_mode)) snprintf(info->executable, sizeof info->executable, "%s/Contents/MacOS/%s", path, ai.executable);
    else snprintf(info->executable, sizeof info->executable, "%s", path);
    const char *base = strrchr(path, '/');
    snprintf(info->name, sizeof info->name, "%s", ai.name[0] ? ai.name : base ? base + 1 : path);
    snprintf(info->identifier, sizeof info->identifier, "%s", ai.identifier);
    snprintf(info->min_macos, sizeof info->min_macos, "%s", ai.min_macos[0] ? ai.min_macos : ai.build_min_macos);
    info->arm64 = ai.has_arm64 || ai.has_arm64e;
    info->x86_64 = ai.has_x86_64;
    int appkit = 0, swiftui = 0, catalyst = 0;
    scan_file(info->executable, info, &appkit, &swiftui, &catalyst);
    if (S_ISDIR(st.st_mode)) scan_frameworks(path, &appkit, &swiftui, &catalyst);
    info->kind = !info->arm64 ? HENGE_TL_INTEL : catalyst ? HENGE_TL_CATALYST : appkit ? HENGE_TL_APPKIT
               : swiftui ? HENGE_TL_SWIFTUI : HENGE_TL_PROGRAM;
    return 0;
}

/* ---- running ---- */

static _Atomic int exit_code;
static _Atomic int g_tl_running;
static _Atomic int runs;
static TlHost g_tl_host;
static int g_tl_host_inited;
static pthread_mutex_t g_stdin_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_stdin_wr = -1;
static char g_cwd[2048];
static char g_mac_apps_dir[2048];
static char g_shared_dir[2048];

/* The program's exit() ends its own thread, not Henge. */
static void guest_exit(int code) {
    fflush(NULL);
    atomic_store(&exit_code, code);
    pthread_exit(NULL);
}

static void *shim_lookup(const char *install_name, const char *symbol) {
    if (!strstr(install_name, "libSystem") && !strstr(install_name, "libsystem_c")) return NULL;
    if (!strcmp(symbol, "_exit") || !strcmp(symbol, "__exit") || !strcmp(symbol, "__Exit")) return (void *)guest_exit;
    return NULL;
}

static void log_line(const char *line) { fprintf(stderr, "%s\n", line); }

/* Keep UI Run button enabled across sequential CLI runs; only set when an AppKit window app marks it. */
int henge_tl_ran_program(void) { return atomic_load(&runs); }
void henge_tl_mark_ran(void) { atomic_store(&runs, 1); }
int henge_tl_is_running(void) { return atomic_load(&g_tl_running); }

static void ensure_dirs(void) {
    if (g_mac_apps_dir[0]) return;
    const char *home = getenv("HOME");
    if (!home || !*home) home = "/tmp";
    snprintf(g_mac_apps_dir, sizeof g_mac_apps_dir, "%s/Documents/Mac Apps", home);
    snprintf(g_shared_dir, sizeof g_shared_dir, "%s/Documents/Shared", home);
    char docs[2048];
    snprintf(docs, sizeof docs, "%s/Documents", home);
    mkdir(docs, 0755);
    mkdir(g_mac_apps_dir, 0755);
    mkdir(g_shared_dir, 0755);
    if (!g_cwd[0]) snprintf(g_cwd, sizeof g_cwd, "%s", g_mac_apps_dir);
}

const char *henge_tl_cwd(void) {
    ensure_dirs();
    return g_cwd;
}

void henge_tl_write_stdin(const char *text) {
    pthread_mutex_lock(&g_stdin_mu);
    if (g_stdin_wr >= 0) {
        if (!text || !*text || (text[0] == 4 && text[1] == 0)) {
            close(g_stdin_wr);
            g_stdin_wr = -1;
        } else {
            size_t len = strlen(text);
            size_t off = 0;
            while (off < len) {
                ssize_t w = write(g_stdin_wr, text + off, len - off);
                if (w <= 0) break;
                off += (size_t)w;
            }
        }
    }
    pthread_mutex_unlock(&g_stdin_mu);
}

/* Splits a command or argument line supporting single quotes, double quotes, and backslash escapes. */
static int split_shell_tokens(const char *line, char ***out_toks) {
    int cap = 16, n = 0;
    char **toks = calloc((size_t)cap, sizeof *toks);
    if (!toks) return 0;
    const char *p = line ? line : "";
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (!*p) break;
        size_t bcap = 64, blen = 0;
        char *buf = malloc(bcap);
        if (!buf) break;
        int sq = 0, dq = 0;
        while (*p) {
            char c = *p;
            if (!sq && !dq && (c == ' ' || c == '\t' || c == '\n' || c == '\r')) break;
            if (!dq && c == '\'') { sq = !sq; p++; continue; }
            if (!sq && c == '"') { dq = !dq; p++; continue; }
            if (!sq && c == '\\' && p[1]) { p++; c = *p; }
            if (blen + 2 > bcap) {
                bcap *= 2;
                char *nb = realloc(buf, bcap);
                if (!nb) break;
                buf = nb;
            }
            buf[blen++] = c;
            p++;
        }
        buf[blen] = 0;
        if (n + 2 > cap) {
            cap *= 2;
            char **nt = realloc(toks, (size_t)cap * sizeof *nt);
            if (!nt) { free(buf); break; }
            toks = nt;
        }
        toks[n++] = buf;
    }
    toks[n] = NULL;
    *out_toks = toks;
    return n;
}

static void free_strv(char **v) {
    if (!v) return;
    for (int i = 0; v[i]; i++) free(v[i]);
    free(v);
}

static void env_set(char ***envp, int *n, int *cap, const char *kv) {
    const char *eq = strchr(kv, '=');
    if (!eq || eq == kv) return;
    size_t klen = (size_t)(eq - kv) + 1;
    for (int i = 0; i < *n; i++) {
        if (!strncmp((*envp)[i], kv, klen)) {
            free((*envp)[i]);
            (*envp)[i] = strdup(kv);
            return;
        }
    }
    if (*n + 2 > *cap) {
        *cap *= 2;
        char **ne = realloc(*envp, (size_t)*cap * sizeof *ne);
        if (!ne) return;
        *envp = ne;
    }
    (*envp)[(*n)++] = strdup(kv);
    (*envp)[*n] = NULL;
}

static char **build_envp(const char *apps_dir) {
    int cap = 32, n = 0;
    char **envp = calloc((size_t)cap, sizeof *envp);
    if (!envp) return NULL;
    const char *tmp = getenv("TMPDIR");
    char kv[4096];
    snprintf(kv, sizeof kv, "HOME=%s", apps_dir);
    env_set(&envp, &n, &cap, kv);
    snprintf(kv, sizeof kv, "TMPDIR=%s", tmp && *tmp ? tmp : "/tmp");
    env_set(&envp, &n, &cap, kv);
    snprintf(kv, sizeof kv, "PATH=%s:/usr/bin:/bin", apps_dir);
    env_set(&envp, &n, &cap, kv);
    env_set(&envp, &n, &cap, "TERM=xterm-256color");
    env_set(&envp, &n, &cap, "USER=henge");
    env_set(&envp, &n, &cap, "LANG=en_US.UTF-8");
    env_set(&envp, &n, &cap, "CI=1");
    env_set(&envp, &n, &cap, "NO_COLOR=1");
    env_set(&envp, &n, &cap, "BUN_JSC_useJIT=0");
    char env_file[2200];
    snprintf(env_file, sizeof env_file, "%s/env.txt", apps_dir);
    FILE *f = fopen(env_file, "r");
    if (f) {
        char line[4096];
        while (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\r\n")] = 0;
            char *s = line;
            while (*s == ' ' || *s == '\t') s++;
            if (!*s || *s == '#') continue;
            if (!strncmp(s, "export ", 7)) s += 7;
            while (*s == ' ' || *s == '\t') s++;
            if (strchr(s, '=')) env_set(&envp, &n, &cap, s);
        }
        fclose(f);
    }
    return envp;
}

typedef struct RunArgs {
    const char *path;
    char *err;
    size_t errlen;
    TlImage *exe;
    int argc;
    const char **argv;
    const char **envp;
} RunArgs;

static void cleanup_run_thread(void *opaque) {
    RunArgs *a = opaque;
    if (a->exe) tl_quiesce_image(a->exe);
    fflush(NULL);
}

static void *run_thread(void *opaque) {
    RunArgs *a = opaque;
    fprintf(stderr, "henge: tl: loading %s\n", a->path);
    a->exe = tl_load(&g_tl_host, a->path, a->err, a->errlen);
    if (!a->exe) {
        fprintf(stderr, "henge: tl: %s\n", a->err);
        return NULL;
    }
    fprintf(stderr, "henge: tl: loaded at %p, %zu bytes, %d missing symbols\n", tl_image_base(a->exe), tl_image_size(a->exe), tl_missing_count());
    pthread_cleanup_push(cleanup_run_thread, a);
    atomic_store(&exit_code, tl_run_main(a->exe, a->argc, a->argv, a->envp));
    pthread_cleanup_pop(1);
    return NULL;
}

static int run_binary(const char *path, const char *args_line, const char *out_path, int append, char *err, size_t errlen) {
    if (atomic_exchange(&g_tl_running, 1))
        return snprintf(err, errlen, "Another program is already running."), -1;
    int vm = henge_vm_state();
    if (vm == 1 || vm == 3 || vm == 4) {
        atomic_store(&g_tl_running, 0);
        return snprintf(err, errlen, "Stop the Mac first: a Mac app and a Mac cannot run at once."), -1;
    }
    HengeDualMapping *jit = henge_ios_jit_get_mapping();
    if (!jit || !jit->rw_addr || !jit->rx_addr) {
        atomic_store(&g_tl_running, 0);
        return snprintf(err, errlen, "Turn on JIT first."), -1;
    }
    if (jit->size < (32u << 20)) {
        atomic_store(&g_tl_running, 0);
        return snprintf(err, errlen, "The JIT region is too small."), -1;
    }
    ensure_dirs();
    if (!g_tl_host_inited) {
        memset(&g_tl_host, 0, sizeof g_tl_host);
        tl_host_init_region(&g_tl_host, jit->rx_addr, jit->rw_addr, jit->size);
        g_tl_host.map_install_name = tl_ios_map_install_name;
        g_tl_host.shim_lookup = shim_lookup;
        g_tl_host.log = log_line;
        g_tl_host.soft_missing = 1;
        g_tl_host.no_processes = 1;
        g_tl_host.ios_kernel_rules = 1;
#if TARGET_OS_IPHONE
        g_tl_host.high_rooms = henge_ios_take_high_room(g_tl_host.high_room, g_tl_host.high_room_bytes);
#endif
        g_tl_host_inited = 1;
    }
    /* From here part of the JIT region may be remapped for the program's data: no Mac in this launch. */
    atomic_store(&henge_tl_ran, 1);
    char **parsed = NULL;
    int nparsed = split_shell_tokens(args_line, &parsed);
    char **argv = calloc((size_t)nparsed + 2, sizeof *argv);
    if (!argv) {
        free_strv(parsed);
        atomic_store(&g_tl_running, 0);
        return snprintf(err, errlen, "Out of memory."), -1;
    }
    argv[0] = strdup(path);
    for (int i = 0; i < nparsed; i++) argv[i + 1] = parsed[i];
    free(parsed);
    int argc = nparsed + 1;
    char **envp = build_envp(g_mac_apps_dir);
    tl_set_main_args(argc, argv);

    int out = open(out_path, O_CREAT | O_WRONLY | (append ? O_APPEND : O_TRUNC), 0644);
    int inpipe[2] = {-1, -1};
    int has_in = pipe(inpipe) == 0;
    fflush(NULL);
    int saved0 = dup(0), saved1 = dup(1), saved2 = dup(2);
    if (has_in) {
        if (saved0 >= 0) dup2(inpipe[0], 0);
        close(inpipe[0]);
        pthread_mutex_lock(&g_stdin_mu);
        g_stdin_wr = inpipe[1];
        pthread_mutex_unlock(&g_stdin_mu);
    }
    if (out >= 0) {
        dup2(out, 1);
        dup2(out, 2);
        close(out);
    }
    char caller_cwd[PATH_MAX] = "";
    if (!getcwd(caller_cwd, sizeof caller_cwd)) caller_cwd[0] = 0;
    char resolved_path[PATH_MAX];
    const char *exec_path = realpath(path, resolved_path) ? resolved_path : path;
    if (g_cwd[0]) chdir(g_cwd);
    atomic_store(&exit_code, -1);
    RunArgs a = {exec_path, err, errlen, NULL, argc, (const char **)argv, (const char **)envp};
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 20u << 20);
    pthread_t t;
    int started = pthread_create(&t, &attr, run_thread, &a) == 0;
    pthread_attr_destroy(&attr);
    if (started) pthread_join(t, NULL);
    pthread_mutex_lock(&g_stdin_mu);
    if (g_stdin_wr >= 0) {
        close(g_stdin_wr);
        g_stdin_wr = -1;
    }
    pthread_mutex_unlock(&g_stdin_mu);
    fflush(NULL);
    if (saved0 >= 0) { dup2(saved0, 0); close(saved0); }
    if (saved1 >= 0) { dup2(saved1, 1); close(saved1); }
    if (saved2 >= 0) { dup2(saved2, 2); close(saved2); }
    if (caller_cwd[0]) chdir(caller_cwd);
    free_strv(argv);
    free_strv(envp);
    atomic_store(&g_tl_running, 0);
    if (!started) return snprintf(err, errlen, "No thread for the program."), -1;
    if (!a.exe) return -1;
    int code = atomic_load(&exit_code);
    fprintf(stderr, "henge: tl: %s returned %d\n", path, code);
    return code;
}

int henge_tl_run_args(const char *path, const char *args_line, const char *out_path, char *err, size_t errlen) {
    return run_binary(path, args_line, out_path, 0, err, errlen);
}

int henge_tl_run(const char *path, const char *out_path, char *err, size_t errlen) {
    return run_binary(path, NULL, out_path, 0, err, errlen);
}

/* ---- built-in terminal commands & program dispatch ---- */

static void resolve_rel(const char *arg, char *out, size_t len) {
    ensure_dirs();
    if (!arg || !*arg || !strcmp(arg, "~")) snprintf(out, len, "%s", g_mac_apps_dir);
    else if (!strncmp(arg, "~/", 2)) snprintf(out, len, "%s/%s", g_mac_apps_dir, arg + 2);
    else if (!strcmp(arg, "shared") || !strcmp(arg, "~/Shared")) snprintf(out, len, "%s", g_shared_dir);
    else if (arg[0] == '/') snprintf(out, len, "%s", arg);
    else snprintf(out, len, "%s/%s", g_cwd, arg);
}

static void term_ls(FILE *f, int argc, char **argv) {
    int show_all = 0, long_fmt = 0;
    const char *target = g_cwd;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-') {
            if (strchr(argv[i], 'a')) show_all = 1;
            if (strchr(argv[i], 'l')) long_fmt = 1;
        } else {
            target = argv[i];
        }
    }
    char path[4096];
    resolve_rel(target, path, sizeof path);
    DIR *d = opendir(path);
    if (!d) { fprintf(f, "ls: %s: %s\n", path, strerror(errno)); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!show_all && e->d_name[0] == '.') continue;
        char full[4096];
        snprintf(full, sizeof full, "%s/%s", path, e->d_name);
        struct stat st;
        int ok = stat(full, &st) == 0;
        int dir = ok && S_ISDIR(st.st_mode);
        if (long_fmt && ok) fprintf(f, "%c %10lld  %s%s\n", dir ? 'd' : '-', (long long)st.st_size, e->d_name, dir ? "/" : "");
        else fprintf(f, "%s%s\n", e->d_name, dir ? "/" : "");
    }
    closedir(d);
}

static void term_cat(FILE *f, const char *arg, int max_lines) {
    if (!arg) { fprintf(f, "usage: %s <file>\n", max_lines > 0 ? "head" : "cat"); return; }
    char path[4096];
    resolve_rel(arg, path, sizeof path);
    FILE *in = fopen(path, "r");
    if (!in) { fprintf(f, "%s: %s\n", path, strerror(errno)); return; }
    char buf[4096];
    int lines = 0;
    while (fgets(buf, sizeof buf, in)) {
        fputs(buf, f);
        if (max_lines > 0 && ++lines >= max_lines) break;
    }
    fclose(in);
}

static void term_cp(FILE *f, const char *src_arg, const char *dst_arg) {
    if (!src_arg || !dst_arg) { fprintf(f, "usage: cp <src> <dst>\n"); return; }
    char src[4096], dst[4096];
    resolve_rel(src_arg, src, sizeof src);
    resolve_rel(dst_arg, dst, sizeof dst);
    FILE *in = fopen(src, "rb");
    if (!in) { fprintf(f, "cp: %s: %s\n", src, strerror(errno)); return; }
    FILE *out = fopen(dst, "wb");
    if (!out) { fclose(in); fprintf(f, "cp: %s: %s\n", dst, strerror(errno)); return; }
    char buf[32768];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
    fclose(out);
    fclose(in);
}

static void term_export(FILE *f, int argc, char **argv) {
    char env_file[2200];
    snprintf(env_file, sizeof env_file, "%s/env.txt", g_mac_apps_dir);
    if (argc < 2 || !strchr(argv[1], '=')) {
        char **envp = build_envp(g_mac_apps_dir);
        for (int i = 0; envp && envp[i]; i++) fprintf(f, "%s\n", envp[i]);
        free_strv(envp);
        return;
    }
    const char *kv = argv[1];
    const char *eq = strchr(kv, '=');
    size_t klen = (size_t)(eq - kv) + 1;
    char lines[64][4096];
    int n = 0, replaced = 0;
    FILE *in = fopen(env_file, "r");
    if (in) {
        while (n < 64 && fgets(lines[n], sizeof lines[n], in)) {
            lines[n][strcspn(lines[n], "\r\n")] = 0;
            if (!strncmp(lines[n], kv, klen)) {
                snprintf(lines[n], sizeof lines[n], "%s", kv);
                replaced = 1;
            }
            n++;
        }
        fclose(in);
    }
    FILE *out = fopen(env_file, "w");
    if (!out) { fprintf(f, "export: cannot write %s: %s\n", env_file, strerror(errno)); return; }
    for (int i = 0; i < n; i++)
        if (lines[i][0]) fprintf(out, "%s\n", lines[i]);
    if (!replaced) fprintf(out, "%s\n", kv);
    fclose(out);
    fprintf(f, "saved %.*s in env.txt\n", (int)(eq - kv), kv);
}

static void term_help(FILE *f) {
    fprintf(f, "Built-in commands: help, pwd, cd [dir], ls [-la] [dir], cat, head, mkdir, rm, cp, env, export KEY=VAL, clear\n");
    fprintf(f, "Programs in Mac Apps (%s):\n", g_mac_apps_dir);
    DIR *d = opendir(g_mac_apps_dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        size_t len = strlen(e->d_name);
        if (len > 4 && !strcmp(e->d_name + len - 4, ".txt")) continue;
        char full[4096];
        snprintf(full, sizeof full, "%s/%s", g_mac_apps_dir, e->d_name);
        HengeTlInfo info;
        char err[128];
        if (henge_tl_info(full, &info, err, sizeof err) == 0) fprintf(f, "  %s\n", e->d_name);
    }
    closedir(d);
}

static int resolve_program(const char *cmd, char *out, size_t len) {
    char candidates[5][4096];
    int nc = 0;
    if (strchr(cmd, '/')) {
        resolve_rel(cmd, candidates[nc++], sizeof candidates[0]);
    } else {
        snprintf(candidates[nc++], sizeof candidates[0], "%s/%s", g_cwd, cmd);
        snprintf(candidates[nc++], sizeof candidates[0], "%s/%s", g_mac_apps_dir, cmd);
        if (!strcmp(cmd, "agy"))
            snprintf(candidates[nc++], sizeof candidates[0], "%s/antigravity", g_mac_apps_dir);
        snprintf(candidates[nc++], sizeof candidates[0], "%s/%s", g_shared_dir, cmd);
    }
    HengeTlInfo info;
    char err[128];
    for (int i = 0; i < nc; i++) {
        if (henge_tl_info(candidates[i], &info, err, sizeof err) == 0 && info.executable[0]) {
            snprintf(out, len, "%s", info.executable);
            return 1;
        }
    }
    return 0;
}

int henge_tl_terminal_exec(const char *cmdline, const char *out_path, char *err, size_t errlen) {
    ensure_dirs();
    if (!cmdline) return 0;
    while (*cmdline == ' ' || *cmdline == '\t') cmdline++;
    if (!*cmdline) return 0;
    char **argv = NULL;
    int argc = split_shell_tokens(cmdline, &argv);
    if (!argc) { free_strv(argv); return 0; }
    if (!strcmp(argv[0], "clear")) {
        FILE *f = fopen(out_path, "w");
        if (f) fclose(f);
        free_strv(argv);
        return 0;
    }
    FILE *f = fopen(out_path, "a");
    if (!f) {
        free_strv(argv);
        return snprintf(err, errlen, "cannot open output: %s", strerror(errno)), -1;
    }
    fprintf(f, "$ %s\n", cmdline);
    const char *cmd = argv[0];
    int rc = 0;
    if (!strcmp(cmd, "pwd")) {
        fprintf(f, "%s\n", g_cwd);
    } else if (!strcmp(cmd, "cd")) {
        char path[4096];
        resolve_rel(argc > 1 ? argv[1] : NULL, path, sizeof path);
        if (chdir(path) == 0) {
            if (!getcwd(g_cwd, sizeof g_cwd)) snprintf(g_cwd, sizeof g_cwd, "%s", path);
        } else {
            fprintf(f, "cd: %s: %s\n", path, strerror(errno));
            rc = 1;
        }
    } else if (!strcmp(cmd, "ls")) {
        term_ls(f, argc, argv);
    } else if (!strcmp(cmd, "cat")) {
        term_cat(f, argc > 1 ? argv[1] : NULL, 0);
    } else if (!strcmp(cmd, "head")) {
        term_cat(f, argc > 1 ? argv[1] : NULL, 40);
    } else if (!strcmp(cmd, "mkdir")) {
        if (argc < 2) fprintf(f, "usage: mkdir <dir>\n");
        else {
            char path[4096];
            resolve_rel(argv[1], path, sizeof path);
            if (mkdir(path, 0755) != 0) fprintf(f, "mkdir: %s: %s\n", path, strerror(errno)), rc = 1;
        }
    } else if (!strcmp(cmd, "rm")) {
        if (argc < 2) fprintf(f, "usage: rm <path>\n");
        else {
            char path[4096];
            resolve_rel(argv[1], path, sizeof path);
            if (unlink(path) != 0 && rmdir(path) != 0) fprintf(f, "rm: %s: %s\n", path, strerror(errno)), rc = 1;
        }
    } else if (!strcmp(cmd, "cp")) {
        term_cp(f, argc > 1 ? argv[1] : NULL, argc > 2 ? argv[2] : NULL);
    } else if (!strcmp(cmd, "env") || !strcmp(cmd, "export")) {
        term_export(f, argc, argv);
    } else if (!strcmp(cmd, "help")) {
        term_help(f);
    } else {
        char exe[4096];
        if (!resolve_program(cmd, exe, sizeof exe)) {
            fprintf(f, "%s: command not found (try 'help')\n", cmd);
            fclose(f);
            free_strv(argv);
            return 127;
        }
        fclose(f);
        /* Pass everything after argv[0] straight through to run_binary. */
        const char *rest = cmdline;
        int q = 0;
        while (*rest && (q || (*rest != ' ' && *rest != '\t'))) {
            if (*rest == '"' || *rest == '\'') q = q == *rest ? 0 : (q ? q : *rest);
            rest++;
        }
        free_strv(argv);
        return run_binary(exe, rest, out_path, 1, err, errlen);
    }
    fclose(f);
    free_strv(argv);
    return rc;
}
