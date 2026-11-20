// SPDX-License-Identifier: GPL-2.0-or-later
/* hengelinux: boot a Linux kernel on HengeVM's engine from the command line,
   with the serial console on this terminal. A development tool for the Linux
   machine (devices/linuxvirt.c); it builds on macOS and on arm64 Linux
   (make linux-test, which also runs under qemu-aarch64 on an x86 host).

     hengelinux --kernel Image [--initrd initrd] [--disk disk.img] [--ram MB]
                [--cpus N] [--append "console=ttyAMA0 ..."] [--fb WxH] [--usb] [--gpu]

   --usb adds the xHCI controller with the USB keyboard and trackpad, which
   Linux's driver does not get along with yet (docs/linux-machine.md). --gpu
   makes virtio-gpu the display (--fb then the size it prefers) instead of the
   framebuffer, and --virgl gives it 3D through the host's virglrenderer.
*/
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include "dispatch.h"
#include "vgpu_virgl.h"
#include "linuxvirt.h"
#include "machine.h"

static HvMachine m;
static HvCpu cpus[HV_MAX_CPUS];
static HvVmapple board = {.ram_fd = -1}; /* the devices */
static HvLinuxVirt lv;
static void save_screen(const char *when);
static atomic_int stopping;
static struct termios saved_tty;
static int tty_raw;
static atomic_int screen_saved;

/* The framebuffer as a PPM image at $HV_FB_DUMP. */
static void save_screen(const char *when) {
    const char *path = getenv("HV_FB_DUMP");
    uint8_t *shot = NULL;
    const uint8_t *pixels = lv.fb;
    uint32_t w = lv.fb_width, h = lv.fb_height;
    if (lv.gpu) { /* what virtio-gpu scans out, with the pointer */
        pixels = hv_virtio_gpu_snapshot(lv.gpu, &shot, &w, &h) == 0 ? shot : NULL;
        if (!pixels) fprintf(stderr, "\nhengelinux: virtio-gpu has nothing on screen (%s)\n", when);
    }
    FILE *pf = path && pixels ? fopen(path, "wb") : NULL;
    if (!pf) {
        free(shot);
        return;
    }
    fprintf(pf, "P6\n%u %u\n255\n", w, h);
    for (uint64_t i = 0; i < (uint64_t)w * h; i++) {
        const uint8_t *px = pixels + i * 4; /* B, G, R, A in memory */
        uint8_t rgb[3] = {px[2], px[1], px[0]};
        fwrite(rgb, 1, 3, pf);
    }
    fclose(pf);
    free(shot);
    if (lv.gpu) fprintf(stderr, "\nhengelinux: virtio-gpu screen %ux%u, %llu frames\n", w, h, (unsigned long long)hv_virtio_gpu_frames(lv.gpu));
    atomic_store(&screen_saved, 1);
    fprintf(stderr, "\nhengelinux: framebuffer (%s) written to %s\n", when, path);
}

/* The serial console to this terminal, watching for the self-test's request for a screenshot. */
static void console_out(void *opaque, uint8_t c) {
    (void)opaque;
    static char line[256];
    static size_t n;
    fputc(c, stdout);
    if (c != '\n') {
        if (n < sizeof line - 1) line[n++] = (char)c;
        return;
    }
    fflush(stdout);
    line[n] = 0;
    n = 0;
    if (strstr(line, "henge-autotest: screenshot")) save_screen("when the guest asked");
}

static uint8_t *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = n > 0 ? malloc((size_t)n) : NULL;
    if (buf && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        buf = NULL;
    }
    fclose(f);
    *len = buf ? (size_t)n : 0;
    return buf;
}

/* As host/vm.c: the guest's SP is in the host SP register while a block runs,
   so signals get a stack of their own and only faults reach CPU threads. */
static void prepare_cpu_thread(void) {
    stack_t ss = {.ss_sp = malloc(1u << 16), .ss_size = 1u << 16, .ss_flags = 0};
    if (ss.ss_sp) sigaltstack(&ss, NULL);
    sigset_t set;
    sigfillset(&set);
    sigdelset(&set, SIGSEGV), sigdelset(&set, SIGBUS), sigdelset(&set, SIGILL), sigdelset(&set, SIGTRAP), sigdelset(&set, SIGFPE);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
}

static void *secondary_thread(void *arg) {
    HvCpu *c = arg;
    prepare_cpu_thread();
    hv_run(c);
    return NULL;
}

static void *kicker_thread(void *unused) {
    (void)unused;
    while (!atomic_load(&stopping)) {
        usleep(1000);
        hv_machine_kick_all(&m);
    }
    return NULL;
}

/* The terminal's keystrokes go to the PL011. Ctrl-A x quits. */
static void *console_thread(void *unused) {
    (void)unused;
    int ctrl_a = 0;
    for (;;) {
        uint8_t ch;
        ssize_t n = read(0, &ch, 1);
        if (n <= 0) return NULL;
        if (ctrl_a && ch == 'x') {
            hv_machine_halt(&m, HV_HALT_HOST);
            return NULL;
        }
        ctrl_a = ch == 1;
        if (ctrl_a) continue;
        hv_dev_lock(&m);
        hv_pl011_receive(board.uart, ch);
        hv_dev_unlock(&m);
        hv_machine_kick_all(&m);
    }
}

static void restore_tty(void) {
    if (tty_raw) tcsetattr(0, TCSANOW, &saved_tty);
}

int main(int argc, char **argv) {
    const char *kernel = NULL, *initrd = NULL, *disk_path = NULL, *append = "console=ttyAMA0 earlycon";
    uint64_t ram_mb = 1024;
    int ncpus = 1;
    unsigned fbw = 0, fbh = 0;
    int usb = 0, gpu = 0, virgl = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--kernel") && v) kernel = v, i++;
        else if (!strcmp(a, "--initrd") && v) initrd = v, i++;
        else if (!strcmp(a, "--disk") && v) disk_path = v, i++;
        else if (!strcmp(a, "--append") && v) append = v, i++;
        else if (!strcmp(a, "--ram") && v) ram_mb = strtoull(v, NULL, 0), i++;
        else if (!strcmp(a, "--cpus") && v) ncpus = atoi(v), i++;
        else if (!strcmp(a, "--fb") && v) sscanf(v, "%ux%u", &fbw, &fbh), i++;
        else if (!strcmp(a, "--usb")) usb = 1;
        else if (!strcmp(a, "--gpu")) gpu = 1;
        else if (!strcmp(a, "--virgl")) gpu = virgl = 1;
        else {
            fprintf(stderr, "usage: %s --kernel Image [--initrd file] [--disk img] [--ram MB] [--cpus N] [--append cmdline] [--fb WxH] [--usb] [--gpu] [--virgl]\n", argv[0]);
            return 2;
        }
    }
    if (!kernel) {
        fprintf(stderr, "hengelinux: --kernel is required\n");
        return 2;
    }
    size_t image_len = 0, initrd_len = 0;
    uint8_t *image = slurp(kernel, &image_len), *rd = initrd ? slurp(initrd, &initrd_len) : NULL;
    if (!image || (initrd && !rd)) {
        fprintf(stderr, "hengelinux: cannot read %s\n", !image ? kernel : initrd);
        return 1;
    }
    static HvDisk disk;
    if (disk_path && hv_disk_open(&disk, disk_path, 0, 0) != 0) {
        fprintf(stderr, "hengelinux: cannot open %s\n", disk_path);
        return 1;
    }
    if (hv_machine_init(&m, (size_t)256 << 20) != 0) {
        fprintf(stderr, "hengelinux: cannot set up the JIT region\n");
        return 1;
    }
    m.log = getenv("HV_LOG") != NULL;
    HvLinuxVirtConfig cfg = {.ncpus = ncpus, .ram_size = ram_mb << 20, .disk = disk_path ? &disk : NULL, .usb = usb, .sound = 1, .gpu = gpu,
                             .fb_width = fbw, .fb_height = fbh, .cmdline = append};
    char err[200];
    static HvVgpu3d gl;
    HvVgpuVirgl *vg = NULL;
    if (virgl) { /* 3D through the host's virglrenderer (built with make linux-test LX_VIRGL=1) */
        if ((vg = hv_vgpu_virgl_create(&gl, getenv("HV_VIRGL_GLES") != NULL))) cfg.gl = &gl;
        else fprintf(stderr, "hengelinux: no virgl renderer (not built with LX_VIRGL=1, or no EGL): 2D only\n");
    }
    if (hv_linuxvirt_create(&lv, &board, &m, cpus, &cfg) != 0) {
        fprintf(stderr, "hengelinux: cannot build the machine\n");
        return 1;
    }
    hv_vgpu_virgl_bind(vg, lv.gpu);
    if (hv_linuxvirt_boot(&lv, &cfg, image, image_len, rd, initrd_len, err, sizeof err) != 0) {
        fprintf(stderr, "hengelinux: %s\n", err);
        return 1;
    }
    free(image);
    free(rd);
    board.uart->output = console_out;
    if (getenv("HV_STATS")) m.stats_interval = (uint32_t)atoi(getenv("HV_STATS")); /* seconds between engine statistics */
    fprintf(stderr, "hengelinux: %d CPU(s), %llu MB, kernel at %llx, device tree at %llx%s (Ctrl-A x quits)\n",
            board.ncpus, (unsigned long long)ram_mb, (unsigned long long)lv.kernel_pa,
            (unsigned long long)lv.dtb_pa, lv.initrd_size ? ", initrd" : "");
    if (isatty(0) && tcgetattr(0, &saved_tty) == 0) {
        struct termios raw = saved_tty;
        cfmakeraw(&raw);
        raw.c_oflag |= OPOST | ONLCR;
        if (tcsetattr(0, TCSANOW, &raw) == 0) tty_raw = 1, atexit(restore_tty);
    }
    pthread_t sec[HV_MAX_CPUS], kick, con;
    for (int i = 1; i < board.ncpus; i++) pthread_create(&sec[i], NULL, secondary_thread, &cpus[i]);
    pthread_create(&kick, NULL, kicker_thread, NULL);
    pthread_create(&con, NULL, console_thread, NULL);
    pthread_detach(con);
    prepare_cpu_thread();
    int r = hv_run(&cpus[0]);
    atomic_store(&stopping, 1);
    hv_machine_halt(&m, HV_HALT_HOST);
    for (int i = 1; i < board.ncpus; i++) pthread_join(sec[i], NULL);
    pthread_join(kick, NULL);
    restore_tty();
    /* HV_FB_DUMP: the framebuffer when the guest's console printed "henge-autotest: screenshot", else at the end. */
    if (!screen_saved) save_screen("at the end");
    fprintf(stderr, "\nhengelinux: stopped (reason %d) at pc %llx el%u\n", r, (unsigned long long)cpus[0].pc, cpus[0].el);
    return 0;
}
