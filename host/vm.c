#include "vm.h"
#include "pvg_lite.h"

#include <TargetConditionals.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <stdio.h>
#include <time.h>

#include "usb_host.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "audio_mac.h"
#include "dispatch.h"
#include "dtplant.h"
#include "net_slirp.h"

static HvMachine m;
static HvCpu cpus[HV_MAX_CPUS]; /* the board takes them as an array */
static int ncpus = 1;
static HvVmapple board = {.ram_fd = -1};
static _Atomic int input_stopping = 1;
static void stop_pointer(void);
/* UI display changes may arrive before or during the background machine creation. */
static os_unfair_lock display_lock = OS_UNFAIR_LOCK_INIT;
static CFTypeRef display_layer;
static int display_layer_set;
static _Atomic(HvPvgLite *) display_pvg; /* published only when the board is ready */
static HvDisk disk = {.fd = -1, .wfd = -1}, aux = {.fd = -1, .wfd = -1};
static int machine_created, signals_installed;
static uint64_t boot_args_offset;
static double boot_last_scan;
static int net_on;
static void (*extra_poll)(void);
static void (*exit_cb)(int);
static pthread_t secondary_threads[HV_MAX_CPUS], kicker;
static int secondary_started[HV_MAX_CPUS], kicker_started;
static _Atomic int kicker_stopped;
static pthread_t primary_thread;
static int primary_started;

HvMachine *hv_vm_machine(void) { return &m; }
HvVmapple *hv_vm_board(void) { return &board; }
HvCpu *hv_vm_cpu(int index) { return index >= 0 && index < ncpus ? &cpus[index] : NULL; }
int hv_vm_ncpus(void) { return ncpus; }

/* Boot-args RAM patch, gated by HV_BOOTARGS_APPEND (value: the exact
   string to append). The scanner below (hv_vm_boot_display) finds the
   guest's boot_args struct in RAM by signature, read-only, to display
   iBoot's framebuffer. With the gate set, the first successful detection
   also appends the token to the struct's CommandLine field, in guest RAM,
   through the same board.ram mapping the scanner reads, and latches: one
   attempt per boot, never a loop-rewrite. Without the env var this code
   is inert: hv_bootargs_maybe_patch returns at its first check and the
   poll thread in hv_vm_create is never started.
   CommandLine offset and capacity are NOT defined anywhere in this tree
   (the scanner reads only the Video fields). They come from the published
   arm64 boot_args layout (XNU pexpert arm boot.h, as reproduced in
   PongoOS src/kernel/pongo.h): Revision 0, Version 2, pad 4, virtBase 8,
   physBase 16, memSize 24, topOfKernelData 32, Video[6] 40..87,
   machineType 88, pad 92, deviceTreeP 96, deviceTreeLength 104,
   CommandLine 108 (PongoOS carries a static assert:
   offsetof(deviceTreeLength) + 4 == offsetof(CommandLine)). The first
   fields match this scanner's own q[] indexing exactly (q[1] virtBase,
   q[2] physBase, q[3] memSize, q[5..10] Video). CommandLine capacity is
   256 in the conservative published variant (0x100; a second variant is
   0x260): writes are bounded by 256, inside the field under either. */
#define HV_BOOTARGS_CMDLINE_OFF 108
#define HV_BOOTARGS_CMDLINE_CAP 256
#define HV_BOOTARGS_DTPTR_OFF 96
#define HV_BOOTARGS_DTLEN_OFF 104

static _Atomic int bootargs_patch_state; /* 0 = not attempted, 1 = appended, 2 = not applied */
static _Atomic int bootargs_patch_claimed; /* one attempt, even with concurrent display callers */

static int hv_bootargs_patch_settled(void) { return atomic_load_explicit(&bootargs_patch_state, memory_order_acquire) != 0; }

static void hv_bootargs_not_applied(const char *reason) {
    fprintf(stderr, "bootargs-patch: NOT APPLIED (%s)\n", reason);
    atomic_store_explicit(&bootargs_patch_state, 2, memory_order_release);
}

static double hv_bootargs_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static double bootargs_t0; /* hv_vm_create time (monotonic s) with the gate set; host-t logs are relative to it */

/* The scanner's signature (hv_vm_boot_display) as a pure predicate, shared by
   the arming scan and the interlocks: header, memory fields and Video must
   all be plausible for the candidate at RAM offset off. On success the
   struct's virtBase/physBase/topOfKernelData are returned. */
static int hv_bootargs_sig_ok(const uint8_t *ram, uint64_t size, uint64_t off,
                              uint64_t *virt_out, uint64_t *phys_out, uint64_t *top_out) {
    if (!ram || off + 0x1000 > size) return 0;
    const uint64_t *q = (const uint64_t *)(ram + off);
    const uint16_t *h = (const uint16_t *)(ram + off);
    if (h[0] < 2 || h[0] > 3 || h[1] < 1 || h[1] > 3) return 0;
    if (q[1] >> 40 != 0xfffffe || q[2] < VMAPPLE_MEM || q[2] >= VMAPPLE_MEM + size || q[3] == 0 || q[3] > size) return 0;
    uint64_t base = q[5], row = q[7], w = q[8], hh = q[9], depth = q[10];
    if (w < 320 || w > 8192 || hh < 200 || hh > 8192 || row < w * 4 || (depth & 0xff) != 32) return 0;
    if (base < VMAPPLE_MEM || base - VMAPPLE_MEM + row * hh > size) return 0;
    if (virt_out) *virt_out = q[1];
    if (phys_out) *phys_out = q[2];
    if (top_out) *top_out = q[4];
    return 1;
}

static pthread_mutex_t bootargs_write_mu = PTHREAD_MUTEX_INITIALIZER;

/* Validate the struct at RAM offset found exactly as the poll patch does and append the
   HV_BOOTARGS_APPEND token to its CommandLine. Returns 1 after logging the
   success line (via == NULL: the poll line verbatim; otherwise the same line
   extended with the trigger name and host-t), or 0 with *reason set to a
   static string. Serialized: the poll thread and the vCPU interlocks may
   race to the same struct; the write itself is identical either way. */
static int hv_bootargs_patch_core(uint8_t *ram, uint64_t size, uint64_t found, const char *via, const char **reason) {
    const char *token = getenv("HV_BOOTARGS_APPEND");
    if (!token) { *reason = "gate unset"; return 0; }
    pthread_mutex_lock(&bootargs_write_mu);
    size_t tlen = strlen(token);
    int bad = tlen == 0;
    for (size_t i = 0; i < tlen; i++)
        if (token[i] <= ' ' || token[i] >= 0x7f) bad = 1;
    if (bad) { *reason = "invalid token"; goto fail; }
    if (found + HV_BOOTARGS_CMDLINE_OFF + HV_BOOTARGS_CMDLINE_CAP > size) { *reason = "command line field out of RAM bounds"; goto fail; }
    /* Confidence checks at the same standard the scanner applies to the
       fields it reads: the device tree pointer and length that sit
       immediately before CommandLine must be plausible, and the field
       itself must hold a clean NUL-terminated printable string. */
    uint64_t dtp;
    uint32_t dtlen;
    memcpy(&dtp, ram + found + HV_BOOTARGS_DTPTR_OFF, 8);
    memcpy(&dtlen, ram + found + HV_BOOTARGS_DTLEN_OFF, 4);
    if (dtlen < 256 || dtlen > (16u << 20)) { *reason = "device tree length implausible"; goto fail; }
    if (dtp >= VMAPPLE_MEM && dtp < VMAPPLE_MEM + size) {
        if (dtp - VMAPPLE_MEM + dtlen > size) { *reason = "device tree out of RAM bounds"; goto fail; }
    } else if (dtp >> 40 != 0xfffffe) { *reason = "device tree pointer implausible"; goto fail; }
    char *cmd = (char *)(ram + found + HV_BOOTARGS_CMDLINE_OFF);
    size_t len = 0;
    while (len < HV_BOOTARGS_CMDLINE_CAP && cmd[len]) {
        unsigned char ch = (unsigned char)cmd[len];
        if (ch < ' ' || ch >= 0x7f) { *reason = "command line is not a clean string"; goto fail; }
        len++;
    }
    if (len >= HV_BOOTARGS_CMDLINE_CAP) { *reason = "command line not NUL-terminated within its field"; goto fail; }
    if (strstr(cmd, token)) { *reason = "token already present"; goto fail; }
    size_t sep = len ? 1 : 0;
    if (len + sep + tlen + 1 > HV_BOOTARGS_CMDLINE_CAP) { *reason = "insufficient capacity in command line field"; goto fail; }
    size_t at = len + sep;
    if (sep) cmd[len] = ' ';
    memcpy(cmd + at, token, tlen);
    cmd[at + tlen] = 0;
    if (memcmp(cmd + at, token, tlen) != 0 || cmd[at + tlen] != 0) { *reason = "write-back verify failed"; goto fail; }
    if (via)
        fprintf(stderr, "bootargs-patch: appended '%s' at cmdline offset %zu (was len %zu, now len %zu) via %s at host-t %.3f\n", token, at, len, at + tlen, via, hv_bootargs_now() - bootargs_t0);
    else
        fprintf(stderr, "bootargs-patch: appended '%s' at cmdline offset %zu (was len %zu, now len %zu)\n", token, at, len, at + tlen);
    pthread_mutex_unlock(&bootargs_write_mu);
    return 1;
fail:
    pthread_mutex_unlock(&bootargs_write_mu);
    return 0;
}

static void hv_bootargs_maybe_patch(uint8_t *ram, uint64_t size, uint64_t found) {
    const char *token = getenv("HV_BOOTARGS_APPEND");
    if (!token) return;
    if (hv_bootargs_patch_settled()) return;
    if (atomic_exchange_explicit(&bootargs_patch_claimed, 1, memory_order_acq_rel)) return;
    const char *reason = NULL;
    if (hv_bootargs_patch_core(ram, size, found, NULL, &reason)) {
        atomic_store_explicit(&bootargs_patch_state, 1, memory_order_release);
        return;
    }
    hv_bootargs_not_applied(reason);
}

/* Device-tree plant, gated by HV_DT_PLANT_INTERNAL=1 (independent of
   HV_BOOTARGS_APPEND; the combined configuration sets both). A boot proved the
   override=10 stack start reaches TransportInit's flag-1 ChipsetSelect,
   which logs "Internal controller info missing" because no
   bluetoothInternalControllerInfo property exists in
   IODeviceTree:/options. The 14-byte value cannot survive the NVRAM
   store's name=value string grammar, so the plant is an
   interlock-class RAM patch to the ADT blob itself, delivered at the
   same hook points as the boot-args patch (T1 kernel entry, T2 first
   hypercall, T3 poll/display safety net) and sharing its discipline:
   the validated boot_args struct supplies deviceTreeP/deviceTreeLength;
   the shared core in dtplant.h validates every ADT field, PROVES
   zero-filled page slack of at least 52 bytes before shifting anything,
   inserts, and re-walks the grown blob; any failure logs a signed
   dtplant PASS line and releases the vCPU immediately with the guest
   unharmed. With the gate unset (or not exactly "1") nothing here runs:
   no DT writes, no log lines, behavior identical to the boot-args-only build. */
static _Atomic int dtplant_state; /* 0 = not planted, 1 = planted (or already present) */
static _Atomic int dtplant_t3_claimed;
static _Atomic int dtplant_t1_done, dtplant_t2_done;

static int hv_dtplant_gate_on(void) {
    const char *g = getenv("HV_DT_PLANT_INTERNAL");
    return g && !strcmp(g, "1");
}

static int hv_dtplant_settled(void) { return atomic_load_explicit(&dtplant_state, memory_order_acquire) != 0; }

static void hv_dtplant_pass(const char *via, const char *reason) {
    fprintf(stderr, "dtplant: PASS %s via %s at host-t %.3f\n", reason, via, hv_bootargs_now() - bootargs_t0);
}

/* One plant attempt against the boot_args struct at RAM offset found:
   full signature first, then deviceTreeP/deviceTreeLength locate the
   ADT (deviceTreeP is a guest physical address, or a kernel virtual
   address under the struct's own virtBase/physBase mapping, the QEMU
   vmapple convention), then the dtplant.h core does the work.
   On success the struct's deviceTreeLength grows by 52. Returns 1 on
   plant, or when the goal state already holds. Serialized with the
   boot-args patch on the same write mutex. */
static int hv_dtplant_attempt(uint64_t found, const char *via, const char **reason) {
    uint8_t *ram = board.ram;
    uint64_t size = board.ram_size;
    if (!ram) { *reason = "guest RAM not mapped"; return 0; }
    uint64_t virt = 0, phys = 0;
    if (!hv_bootargs_sig_ok(ram, size, found, &virt, &phys, NULL)) { *reason = "candidate fails the boot_args signature"; return 0; }
    pthread_mutex_lock(&bootargs_write_mu);
    uint64_t dtp;
    uint32_t dtlen;
    memcpy(&dtp, ram + found + HV_BOOTARGS_DTPTR_OFF, 8);
    memcpy(&dtlen, ram + found + HV_BOOTARGS_DTLEN_OFF, 4);
    if (dtlen < 256 || dtlen > (16u << 20)) { *reason = "device tree length implausible"; goto fail; }
    uint64_t pa;
    if (dtp >= VMAPPLE_MEM && dtp < VMAPPLE_MEM + size) pa = dtp;
    else if (dtp >= virt && dtp - virt < size) pa = phys + (dtp - virt);
    else { *reason = "device tree pointer implausible"; goto fail; }
    if (pa < VMAPPLE_MEM || pa >= VMAPPLE_MEM + size || pa - VMAPPLE_MEM + dtlen > size) { *reason = "device tree out of RAM bounds"; goto fail; }
    uint64_t dt_off = pa - VMAPPLE_MEM;
    uint32_t newlen = 0;
    int r = dtplant_insert(ram + dt_off, dtlen, size - dt_off, &newlen, reason);
    if (r == 2) { /* the plant property already present with the exact payload: goal state holds */
        atomic_store_explicit(&dtplant_state, 1, memory_order_release);
        pthread_mutex_unlock(&bootargs_write_mu);
        return 1;
    }
    if (r != 1) goto fail;
    uint32_t check = 0;
    memcpy(ram + found + HV_BOOTARGS_DTLEN_OFF, &newlen, 4);
    memcpy(&check, ram + found + HV_BOOTARGS_DTLEN_OFF, 4);
    if (check != newlen) { *reason = "device tree length write-back verify failed"; goto fail; }
    atomic_store_explicit(&dtplant_state, 1, memory_order_release);
    fprintf(stderr, "dtplant: inserted bluetoothInternalControllerInfo (14 B) into /options, dt len %u -> %u, via %s at host-t %.3f\n",
            dtlen, newlen, via, hv_bootargs_now() - bootargs_t0);
    pthread_mutex_unlock(&bootargs_write_mu);
    return 1;
fail:
    pthread_mutex_unlock(&bootargs_write_mu);
    return 0;
}

/* T3: the poll/display detection path shares the plant routine, as it
   shares the boot-args patch. One attempt, latched, like
   hv_bootargs_maybe_patch. Inert and silent with the gate unset. */
static void hv_dtplant_maybe_plant(uint8_t *ram, uint64_t size, uint64_t found) {
    (void)ram;
    (void)size;
    if (!hv_dtplant_gate_on()) return;
    if (hv_dtplant_settled()) return;
    if (atomic_exchange_explicit(&dtplant_t3_claimed, 1, memory_order_acq_rel)) return;
    const char *reason = NULL;
    if (hv_dtplant_attempt(found, "T3", &reason)) return;
    if (hv_dtplant_settled()) return;
    hv_dtplant_pass("T3", reason ? reason : "plant failed");
}

/* Kernel-entry interlock. The poll patch loses the race to
   arm_init's whole-struct copy (const_boot_args = *args, the kernel's first
   C function): the copy lands inside (3.207, 3.504) s in the observed log while
   the throttled poll fired at 4.787 s. The interlock therefore does not
   poll for the patch itself; it ARMS from the poll thread (the struct's
   identity and the kernel's address range, known once the final iBoot
   stage has built the struct, well before handoff) and PATCHES
   synchronously on the vCPU thread at one of two events that provably
   precede the copy:
     T1 (dispatcher, core/dispatch.c run_loop via m->bootargs_fetch_hook):
        the first block fetch whose PC enters the kernel range
        [physBase, topOfKernelData) (or its virtBase image once the MMU is
        on) from outside it, on CPU 0 at EL1. No kernel instruction of
        that block has executed yet; x0 still holds the entry value iBoot
        passed, the boot_args pointer per the arm64 boot convention.
        The first-ever fetch of the entry block cannot be chained or
        IJC-cached (it was never translated), so the dispatcher always
        sees it. This is strictly before arm_init.
     T2 (HVC, core/exception.c hv_exception_insn via m->bootargs_hvc_hook):
        the first EL1 hypercall from CPU 0 at which a boot_args struct is
        identifiable. x0 at an HVC is the call number (psci() consumes
        it), NOT the entry pointer, so the struct is located by scanning
        x1..x30 for a pointer that passes the full signature (the entry
        value survives in a callee-saved register across the call), then
        by the armed offset. These calls (0x8300ff01 class, observed log
        t=3.214) are _start's platform/PAC setup, before arm_init runs.
   T3 is the poll patch above, unchanged, as the safety net.
   Fail-safes: an interlock attempt validates its target with the scanner
   signature PLUS the poll patch's field validation before writing; any failure logs
   INTERLOCK PASS and returns at once (the vCPU is never held, nothing
   loops or waits on this path; the write mutex is held only for the
   bounded validate-and-write). A PASS spends that trigger only; the
   other trigger and the T3 net remain live. With HV_BOOTARGS_APPEND
   unset the hooks are never installed (hv_vm_create) and this code is
   unreachable. */
static _Atomic int bootargs_arm_valid;
static _Atomic uint64_t bootargs_arm_found, bootargs_arm_phys, bootargs_arm_top, bootargs_arm_virt;
static _Atomic int bootargs_arm_range_ok;
static _Atomic int bootargs_t1_done, bootargs_t2_done;

static int hv_bootargs_scan_raw(uint8_t *ram, uint64_t size, uint64_t *found_out, uint64_t *virt_out, uint64_t *phys_out, uint64_t *top_out) {
    uint64_t limit = size < (1ull << 30) ? size : 1ull << 30;
    for (uint64_t off = 0; off + 0x1000 <= limit; off += 0x4000) {
        if (!hv_bootargs_sig_ok(ram, size, off, virt_out, phys_out, top_out)) continue;
        *found_out = off;
        return 1;
    }
    return 0;
}

static void hv_bootargs_try_arm(void) {
    if (atomic_load_explicit(&bootargs_arm_valid, memory_order_acquire)) return;
    uint8_t *ram = board.ram;
    uint64_t size = board.ram_size;
    if (!ram) return;
    uint64_t found, virt, phys, top;
    if (!hv_bootargs_scan_raw(ram, size, &found, &virt, &phys, &top)) return;
    atomic_store_explicit(&bootargs_arm_found, found, memory_order_release);
    atomic_store_explicit(&bootargs_arm_phys, phys, memory_order_release);
    atomic_store_explicit(&bootargs_arm_top, top, memory_order_release);
    atomic_store_explicit(&bootargs_arm_virt, virt, memory_order_release);
    int range_ok = top > phys && top - phys <= size;
    atomic_store_explicit(&bootargs_arm_range_ok, range_ok, memory_order_release);
    atomic_store_explicit(&bootargs_arm_valid, 1, memory_order_release);
    fprintf(stderr, "bootargs-patch: interlock armed at host-t %.3f (struct RAM offset %#llx, kernel PA range %#llx-%#llx%s)\n",
            hv_bootargs_now() - bootargs_t0, (unsigned long long)found, (unsigned long long)phys, (unsigned long long)top,
            range_ok ? "" : ", range implausible: T1 falls back to the entry point only");
}

/* A guest pointer (physical, or kernel-virtual under the armed struct's
   virtBase/physBase mapping) to a RAM offset, or 0. */
static int hv_bootargs_off_from_ptr(uint64_t ptr, uint64_t *off_out) {
    uint64_t size = board.ram_size;
    if (!board.ram) return 0;
    if (ptr >= VMAPPLE_MEM && ptr < VMAPPLE_MEM + size) { *off_out = ptr - VMAPPLE_MEM; return 1; }
    if (atomic_load_explicit(&bootargs_arm_valid, memory_order_acquire)) {
        uint64_t virt = atomic_load_explicit(&bootargs_arm_virt, memory_order_acquire);
        uint64_t phys = atomic_load_explicit(&bootargs_arm_phys, memory_order_acquire);
        if (ptr >= virt && ptr - virt < size) {
            uint64_t pa = phys + (ptr - virt);
            if (pa >= VMAPPLE_MEM && pa < VMAPPLE_MEM + size) { *off_out = pa - VMAPPLE_MEM; return 1; }
        }
    }
    return 0;
}

/* One interlock attempt against the struct at RAM offset off: full
   signature first (the interlock paths derive off from a register, not
   from the scanner), then the shared core. On success the patch settles for
   every path. Never waits or retries. */
static int hv_bootargs_interlock_attempt(uint64_t off, const char *via, const char **reason) {
    uint8_t *ram = board.ram;
    uint64_t size = board.ram_size;
    if (!ram) { *reason = "guest RAM not mapped"; return 0; }
    if (!hv_bootargs_sig_ok(ram, size, off, NULL, NULL, NULL)) { *reason = "candidate fails the boot_args signature"; return 0; }
    if (!hv_bootargs_patch_core(ram, size, off, via, reason)) {
        if (*reason && !strcmp(*reason, "token already present")) {
            /* The goal state (token in the struct before the copy) already
               holds, reached by whichever path wrote first. */
            atomic_store_explicit(&bootargs_patch_state, 1, memory_order_release);
            atomic_store_explicit(&bootargs_patch_claimed, 1, memory_order_release);
            return 1;
        }
        return 0;
    }
    atomic_store_explicit(&bootargs_patch_state, 1, memory_order_release);
    atomic_store_explicit(&bootargs_patch_claimed, 1, memory_order_release);
    return 1;
}

static void hv_bootargs_interlock_pass(const char *via, const char *reason) {
    fprintf(stderr, "bootargs-patch: INTERLOCK PASS (%s) via %s at host-t %.3f\n", reason, via, hv_bootargs_now() - bootargs_t0);
}

static int hv_bootargs_in_kernel_range(HvCpu *cpu, uint64_t pc, uint64_t phys, uint64_t top, uint64_t virt, int range_ok) {
    if (cpu->sctlr_el1 & 1) { /* MMU on: PCs are virtual */
        if (range_ok) return pc >= virt && pc - virt < top - phys;
        return pc == virt;
    }
    if (range_ok) return pc >= phys && pc < top;
    return pc == phys;
}

/* T1: see the design comment above. Called by the dispatcher before the
   fetch of every block while armed; fast-outs until the entry edge. */
static void hv_bootargs_t1_fetch(HvCpu *cpu, uint64_t prev_pc) {
    if (cpu->index != 0 || cpu->el != 1) return;
    /* Each patch spends its own T1 latch; with the DT gate unset the
       boot-args flow below is the original flow unchanged. */
    int ba_active = getenv("HV_BOOTARGS_APPEND") && !hv_bootargs_patch_settled();
    int dt_active = hv_dtplant_gate_on() && !hv_dtplant_settled();
    if (!ba_active && !dt_active) return;
    if (!atomic_load_explicit(&bootargs_arm_valid, memory_order_acquire)) return;
    uint64_t phys = atomic_load_explicit(&bootargs_arm_phys, memory_order_acquire);
    uint64_t top = atomic_load_explicit(&bootargs_arm_top, memory_order_acquire);
    uint64_t virt = atomic_load_explicit(&bootargs_arm_virt, memory_order_acquire);
    int range_ok = atomic_load_explicit(&bootargs_arm_range_ok, memory_order_acquire);
    if (!hv_bootargs_in_kernel_range(cpu, cpu->pc, phys, top, virt, range_ok)) return;
    if (hv_bootargs_in_kernel_range(cpu, prev_pc, phys, top, virt, range_ok)) return; /* not the first fetch */
    uint64_t off = 0;
    int have_off = hv_bootargs_off_from_ptr(cpu->x[0], &off);
    if (ba_active && !atomic_exchange_explicit(&bootargs_t1_done, 1, memory_order_acq_rel)) {
        const char *reason = NULL;
        if (!(have_off && hv_bootargs_interlock_attempt(off, "T1", &reason))) {
            if (!reason) reason = "x0 does not identify a valid boot_args struct";
            if (!hv_bootargs_patch_settled()) hv_bootargs_interlock_pass("T1", reason); /* another path may have won while we validated */
        }
    }
    if (dt_active && !atomic_exchange_explicit(&dtplant_t1_done, 1, memory_order_acq_rel)) {
        const char *reason = NULL;
        if (!(have_off && hv_dtplant_attempt(off, "T1", &reason))) {
            if (!reason) reason = "x0 does not identify a valid boot_args struct";
            if (!hv_dtplant_settled()) hv_dtplant_pass("T1", reason);
        }
    }
}

/* T2: see the design comment above. Called on every EL1 HVC from the
   exception path, before psci() answers (and overwrites x0). */
static void hv_bootargs_t2_hvc(HvCpu *cpu, uint64_t fn) {
    (void)fn;
    if (cpu->index != 0 || cpu->el != 1) return;
    /* Each patch spends its own T2 latch (below); with the DT gate
       unset the boot-args flow is the original flow unchanged. */
    int ba_active = getenv("HV_BOOTARGS_APPEND") && !hv_bootargs_patch_settled();
    int dt_active = hv_dtplant_gate_on() && !hv_dtplant_settled();
    if (!ba_active && !dt_active) return;
    /* Eligibility: a boot_args struct must be identifiable right now (armed
       by the scan, or pointed to by a live register passing the full
       signature). An earlier hypercall with no identifiable struct is the
       firmware still building it: not the kernel's first call, and it does
       not spend the trigger. */
    int have_armed = atomic_load_explicit(&bootargs_arm_valid, memory_order_acquire);
    uint64_t armed_off = have_armed ? atomic_load_explicit(&bootargs_arm_found, memory_order_acquire) : 0;
    uint64_t reg_off[31];
    int nreg = 0, reg_is_armed = 0;
    for (int i = 1; i <= 30; i++) {
        uint64_t off;
        if (!hv_bootargs_off_from_ptr(cpu->x[i], &off)) continue;
        if (!hv_bootargs_sig_ok(board.ram, board.ram_size, off, NULL, NULL, NULL)) continue;
        if (have_armed && off == armed_off) reg_is_armed = 1;
        else reg_off[nreg++] = off;
    }
    if (!have_armed && !nreg && !reg_is_armed) return;
    if (ba_active && !atomic_exchange_explicit(&bootargs_t2_done, 1, memory_order_acq_rel)) {
        const char *reason = NULL;
        int ok = 0;
        if (reg_is_armed && hv_bootargs_interlock_attempt(armed_off, "T2", &reason)) ok = 1;
        for (int i = 0; i < nreg && !ok; i++)
            if (hv_bootargs_interlock_attempt(reg_off[i], "T2", &reason)) ok = 1;
        if (!ok && have_armed && !reg_is_armed && hv_bootargs_interlock_attempt(armed_off, "T2", &reason)) ok = 1;
        if (!ok) {
            if (!reason) reason = "no register or armed struct validates as boot_args at the first hypercall";
            if (!hv_bootargs_patch_settled()) hv_bootargs_interlock_pass("T2", reason);
        }
    }
    if (dt_active && !atomic_exchange_explicit(&dtplant_t2_done, 1, memory_order_acq_rel)) {
        const char *reason = NULL;
        int ok = 0;
        if (reg_is_armed && hv_dtplant_attempt(armed_off, "T2", &reason)) ok = 1;
        for (int i = 0; i < nreg && !ok; i++)
            if (hv_dtplant_attempt(reg_off[i], "T2", &reason)) ok = 1;
        if (!ok && have_armed && !reg_is_armed && hv_dtplant_attempt(armed_off, "T2", &reason)) ok = 1;
        if (!ok) {
            if (!reason) reason = "no register or armed struct validates as boot_args at the first hypercall";
            if (!hv_dtplant_settled()) hv_dtplant_pass("T2", reason);
        }
    }
}

/* Settled means every ENABLED patch has settled; with the DT gate
   unset this is exactly hv_bootargs_patch_settled(). */
static int hv_patches_all_settled(void) {
    if (getenv("HV_BOOTARGS_APPEND") && !hv_bootargs_patch_settled()) return 0;
    if (hv_dtplant_gate_on() && !hv_dtplant_settled()) return 0;
    return 1;
}

static void *hv_bootargs_poll_thread(void *unused) {
    (void)unused;
    HvBootDisplay d;
    while (!hv_patches_all_settled()) {
        hv_bootargs_try_arm(); /* arm the interlocks the moment the struct is signature-valid */
        hv_vm_boot_display(&d);
        if (hv_patches_all_settled()) break;
        usleep(50000);
    }
    return NULL;
}

/* arm64 boot_args: {u16 Revision, u16 Version, u64 virtBase, physBase, memSize,
   topOfKernelData, Video {baseAddr, display, rowBytes, width, height, depth}, ...}.
   Found by scanning page starts for one whose physBase is the RAM base. */
int hv_vm_boot_display(HvBootDisplay *d) {
    /* What the guest's GPU has drawn, once it has drawn anything. */
    HvPvgLite *pvg = atomic_load_explicit(&display_pvg, memory_order_acquire);
    if (!pvg) return -1;
    const uint8_t *frame;
    uint32_t fw, fh;
    if (hv_pvg_lite_frame(pvg, &frame, &fw, &fh) == 0) {
        d->pixels = (uint8_t *)frame;
        d->width = fw, d->height = fh, d->stride = fw * 4;
        return 0;
    }
    uint8_t *ram = board.ram;
    uint64_t size = board.ram_size;
    if (!ram) return -1;
    for (int pass = 0; pass < 2; pass++) {
        if (!boot_args_offset || pass) {
            /* A full scan at most every 2 s; boot_args sits low in RAM
               (iBoot puts it near 0x78ed0000), so the first GB is enough. */
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            double now = ts.tv_sec + ts.tv_nsec * 1e-9;
            if (now - boot_last_scan < 2) return -1;
            boot_last_scan = now;
            if (pass && boot_args_offset) boot_args_offset = 0;
            uint64_t limit = size < (1ull << 30) ? size : 1ull << 30;
            for (uint64_t off = 0; off + 0x1000 <= limit && !boot_args_offset; off += 0x4000) {
                const uint64_t *q = (const uint64_t *)(ram + off);
                const uint16_t *h = (const uint16_t *)(ram + off);
                if (h[0] < 2 || h[0] > 3 || h[1] < 1 || h[1] > 3) continue; /* boot_args: revision, version */
                if (q[1] >> 40 != 0xfffffe || q[2] < VMAPPLE_MEM || q[2] >= VMAPPLE_MEM + size || q[3] == 0 || q[3] > size) continue;
                uint64_t base = q[5], row = q[7], w = q[8], hh = q[9], depth = q[10];
                if (w < 320 || w > 8192 || hh < 200 || hh > 8192 || row < w * 4 || (depth & 0xff) != 32) continue;
                if (base < VMAPPLE_MEM || base - VMAPPLE_MEM + row * hh > size) continue;
                boot_args_offset = off;
                hv_bootargs_maybe_patch(ram, size, off); /* inert unless HV_BOOTARGS_APPEND is set */
                hv_dtplant_maybe_plant(ram, size, off); /* inert unless HV_DT_PLANT_INTERNAL=1 */
            }
        }
        if (!boot_args_offset) return -1;
        const uint64_t *q = (const uint64_t *)(ram + boot_args_offset);
        uint64_t base = q[5], row = q[7], w = q[8], hh = q[9];
        if (q[1] >> 40 == 0xfffffe && w >= 320 && w <= 8192 && hh >= 200 && hh <= 8192 && base >= VMAPPLE_MEM &&
            base - VMAPPLE_MEM + row * hh <= size) {
            d->pixels = ram + (base - VMAPPLE_MEM);
            d->width = (uint32_t)w, d->height = (uint32_t)hh, d->stride = (uint32_t)row;
            return 0;
        }
    }
    return -1;
}
void hv_vm_set_poll(void (*poll)(void)) { extra_poll = poll; }

const char *hv_vm_reason_name(int r) {
    switch (r) {
    case HV_EXIT_HALT: return "halt";
    case HV_EXIT_WFI: return "wfi with nothing to wake it";
    case HV_EXIT_UNSUPPORTED: return "unsupported";
    case HV_EXIT_FAULT_LOOP: return "fault on the exception vector";
    default: return "other";
    }
}

/* Host-side device work on CPU 0's thread each tick. */
static void board_poll(void) {
    if (extra_poll) extra_poll();
    if (net_on) hv_net_poll();
}

static int fail(char *err, size_t n, const char *msg) {
    if (err && n) snprintf(err, n, "%s", msg);
    return -1;
}

/* A branch landing where no translation is (an illegal instruction, or a fault
   fetching one): say where, and which direct branches in translated code lead
   there, for a crash report cannot. */
static struct sigaction prior_ill, prior_bus, prior_segv;
static void on_ill(int sig, siginfo_t *info, void *ctx) {
    ucontext_t *uc = ctx;
    uint64_t pc = uc->uc_mcontext->__ss.__pc, rx = (uint64_t)(uintptr_t)m.jit.base, size = (uint64_t)m.jit.capacity * 4;
    uint64_t used = (uint64_t)m.jit.used * 4;
    int in_rx = pc >= rx && pc < rx + size;
    int fetch = (uint64_t)(uintptr_t)info->si_addr == pc;
    if (sig == SIGILL || in_rx || fetch) {
        fprintf(stderr, "hengevm: signal %d in translated code: pc %llx (rx %llx size %llx used %llx, pc is rx%+lld), full flushes %llu, lr %llx, addr %p\n",
                sig, (unsigned long long)pc, (unsigned long long)rx, (unsigned long long)size, (unsigned long long)used, (long long)(pc - rx),
                (unsigned long long)m.stats.block_flushes, (unsigned long long)uc->uc_mcontext->__ss.__lr, info->si_addr);
        for (int i = 0; i < 29; i++) fprintf(stderr, "x%d=%llx%c", i, (unsigned long long)uc->uc_mcontext->__ss.__x[i], i % 6 == 5 ? '\n' : ' ');
        fprintf(stderr, "\n");
        fprintf(stderr, "sp=%llx ram %llx size %llx\n", (unsigned long long)uc->uc_mcontext->__ss.__sp, (unsigned long long)(uintptr_t)board.ram, (unsigned long long)board.ram_size);
        {
            uint64_t x7 = uc->uc_mcontext->__ss.__x[7], x28 = uc->uc_mcontext->__ss.__x[28];
            if (x7 >= x28 && x7 < x28 + sizeof(HvCpu)) {
                const uint64_t *ent = (const uint64_t *)(uintptr_t)(x7 + 0x500);
                fprintf(stderr, "tlb entry at +%llx:", (unsigned long long)(x7 - x28));
                for (int i = 0; i < 16; i++) fprintf(stderr, " %llx", (unsigned long long)ent[i]);
                fprintf(stderr, "\n");
            }
        }
        for (int i = 0; i < ncpus; i++)
            fprintf(stderr, "  cpu %d: guest pc %llx el%u miss site %llx\n", i, (unsigned long long)cpus[i].pc, cpus[i].el, (unsigned long long)cpus[i].miss_site);
        if (in_rx) { /* the code it ran up to here, as it stands */
            uint64_t from = pc - 0x300 < rx ? rx : pc - 0x300;
            fprintf(stderr, "  words from rx+%llx:", (unsigned long long)(from - rx));
            for (uint64_t at = from; at < pc + 0x600 && at < rx + size; at += 4) {
                if (((at - from) & 0x1f) == 0) fprintf(stderr, "\n   ");
                fprintf(stderr, " %08x", *(const uint32_t *)(uintptr_t)at);
            }
            fprintf(stderr, "\n");
        }
        { /* x15 after a chained exit's check: the literal it loaded. Which exits, and where do they go now? */
            uint64_t x15 = uc->uc_mcontext->__ss.__x[15];
            const uint32_t *w15 = (const uint32_t *)(uintptr_t)rx;
            uint64_t n15 = used / 4 < m.jit.capacity ? used / 4 : m.jit.capacity;
            int shown = 0;
            for (uint64_t k = 0; k + 8 < n15 && shown < 12; k++) {
                if ((w15[k] & 0xff00001fu) != 0x5800000fu) continue; /* ldr x15, literal */
                int64_t lo = (int64_t)(int32_t)(w15[k] << 8) >> 13;
                uint64_t at = k + (uint64_t)lo;
                if (at + 1 >= n15) continue;
                uint64_t lit = w15[at] | (uint64_t)w15[at + 1] << 32;
                if (lit != x15) continue;
                /* eor x6; orr; cbnz; B */
                uint32_t b = w15[k + 4];
                if ((b & 0xfc000000u) != 0x14000000u) continue;
                int64_t off = (int64_t)(b << 6) >> 6;
                fprintf(stderr, "  exit at rx+%llx: B word %08x to rx+%llx\n", (unsigned long long)(k + 4) * 4, b, (unsigned long long)((int64_t)(k + 4) + off) * 4);
                shown++;
            }
        }
        if (!in_rx || pc >= rx + used) {
            /* Who branches there? */
            const uint32_t *w = (const uint32_t *)(uintptr_t)rx;
            int found = 0;
            uint64_t words = used / 4 < m.jit.capacity ? used / 4 : m.jit.capacity;
            for (uint64_t k = 0; k < words && found < 8; k++) {
                uint32_t i = w[k];
                int64_t off;
                if ((i & 0x7c000000u) == 0x14000000u) off = (int64_t)(i << 6) >> 6;
                else if ((i & 0xff000010u) == 0x54000000u || (i & 0x7e000000u) == 0x34000000u) off = (int64_t)(int32_t)(i << 8) >> 13;
                else if ((i & 0x7e000000u) == 0x36000000u) off = (int64_t)(int32_t)(i << 13) >> 18;
                else continue;
                if (rx + k * 4 + (uint64_t)(off * 4) != pc && rx + k * 4 + (uint64_t)(off * 4) != pc - 4) continue;
                found++;
                fprintf(stderr, "  branch at rx+%llx (word %08x) leads there; around it:", (unsigned long long)k * 4, i);
                for (int64_t d = -6; d <= 3; d++)
                    if ((int64_t)k + d >= 0 && (uint64_t)((int64_t)k + d) < words) fprintf(stderr, " %08x", w[k + d]);
                fprintf(stderr, "\n");
            }
            if (!found) fprintf(stderr, "  no direct branch in %llu MB of code leads there\n", (unsigned long long)(used >> 20));
            /* Which slot or cache entry holds it? */
            for (uint32_t k = 0; k < m.max_slots; k++)
                if (m.slots && m.slots[k] == pc) fprintf(stderr, "  chain slot %u holds it\n", k);
        }
        fflush(stderr);
    }
    struct sigaction *prior = sig == SIGILL ? &prior_ill : sig == SIGBUS ? &prior_bus : &prior_segv;
    sigaction(sig, prior, NULL);
}

void (*hv_prof_register)(void);

void hv_vm_set_display_layer(void *layer) {
    CFTypeRef retained = layer ? CFRetain(layer) : NULL;
    os_unfair_lock_lock(&display_lock);
    CFTypeRef previous = display_layer;
    display_layer = retained;
    display_layer_set = 1;
    HvPvgLite *pvg = atomic_load_explicit(&display_pvg, memory_order_acquire);
    if (pvg) hv_pvg_lite_set_layer(pvg, layer);
    os_unfair_lock_unlock(&display_lock);
    if (previous) CFRelease(previous);
}

uint64_t hv_vm_gpu_frames(void) {
    HvPvgLite *pvg = atomic_load_explicit(&display_pvg, memory_order_acquire);
    return pvg ? hv_pvg_lite_gpu_frames(pvg) : 0;
}

int hv_vm_create(const HvVmConfig *c, char *err, size_t errlen) {
    if (machine_created) return fail(err, errlen, "The previous machine has not been released.");
    if (primary_started) {
        pthread_join(primary_thread, NULL);
        primary_started = 0;
    }
    if (!c->rom || !c->disk || !c->aux) return fail(err, errlen, "The ROM, disk and auxiliary storage are all needed.");
    machine_created = 1;
    struct sigaction ill = {.sa_flags = SA_SIGINFO | SA_ONSTACK};
    ill.sa_sigaction = on_ill;
    if (!signals_installed) {
        sigaction(SIGILL, &ill, &prior_ill);
        sigaction(SIGBUS, &ill, &prior_bus);
        sigaction(SIGSEGV, &ill, &prior_segv);
        signals_installed = 1;
    }
    signal(SIGPIPE, SIG_IGN); /* a guest connection closing at the far end must not end the machine */
    if (hv_disk_open(&disk, c->disk, 0, 0) != 0) return fail(err, errlen, "Cannot open the disk image.");
    if (hv_disk_open(&aux, c->aux, c->aux_offset ? c->aux_offset : 16384, 0) != 0)
        return fail(err, errlen, "Cannot open the auxiliary storage.");
    size_t jit = c->jit_bytes ? c->jit_bytes : (size_t)768 << 20;
    int r = c->jit_rx ? hv_machine_init_jit(&m, c->jit_rx, c->jit_rw, jit) : hv_machine_init(&m, jit);
    if (r != 0) return fail(err, errlen, "Cannot set up the JIT region.");
    m.log = c->log;
    m.gen_checks = getenv("HV_JIT_POISON") != NULL;
    if (getenv("HV_SLOW_MEM")) m.slow_mem = 1; /* debugging: every load and store through the helper */
    ncpus = c->ncpus < 1 ? 1 : c->ncpus > HV_MAX_CPUS ? HV_MAX_CPUS : c->ncpus;
    m.big_lock_on = ncpus > 1 && getenv("HV_BIG_LOCK"); /* debugging: one CPU in guest code at a time */
    HvCfgParams cfg = {.nr_cpus = (uint32_t)ncpus, .ecid = c->ecid, .seed = c->seed, .mac_en0 = {0x02, 0x48, 0x56, 0x4d, 0x00, 0x01}};
    if (c->installer) cfg.run_installer1 = cfg.run_installer2 = 1;
    if (getenv("HV_RUN_INSTALLER")) { /* experiment: "a,b" for the two installer words */
        unsigned a = 0, b2 = 0;
        sscanf(getenv("HV_RUN_INSTALLER"), "%u,%u", &a, &b2);
        cfg.run_installer1 = a, cfg.run_installer2 = b2;
    }
    static const uint8_t mac[6] = {0x02, 0x48, 0x56, 0x4d, 0x00, 0x01};
    if (hv_vmapple_create(&board, &m, cpus, (c->ram_mb ? c->ram_mb : 2048) << 20, &disk, &aux, &cfg, mac) != 0)
        return fail(err, errlen, "Cannot build the machine (not enough memory for the guest's RAM?).");
    if (hv_vmapple_load_rom(&board, c->rom) != 0) return fail(err, errlen, "Cannot read the ROM (AVPBooter.vmapple2.bin).");
    hv_vmapple_reset_cpu(&board);
    if (board.net && !c->no_net) {
        if (hv_net_attach(&m, board.net) != 0) fprintf(stderr, "hengevm: user-mode network unavailable\n");
        else net_on = 1;
    }
    if (board.snd && !c->no_sound) hv_audio_attach(board.snd);
    board.poll = board_poll;
    if (board.vusb && getenv("HV_VUSB_PROBE")) hv_usb_probe_start(board.vusb);
    // The setter and publication share this lock: an older preboot target can
    // never overwrite a monitor change made while the board was being built.
    os_unfair_lock_lock(&display_lock);
    if (display_layer_set && board.pvg) hv_pvg_lite_set_layer(board.pvg, (void *)display_layer);
    atomic_store_explicit(&display_pvg, board.pvg, memory_order_release);
    os_unfair_lock_unlock(&display_lock);
    atomic_store(&input_stopping, 0);
    if (getenv("HV_BOOTARGS_APPEND") || hv_dtplant_gate_on()) { /* On this host nothing polls hv_vm_boot_display during boot, so give the scanner a cadence (the poll thread also arms the interlocks); the interlock hooks patch at kernel entry / first hypercall, the poll patch latches at first detection as the safety net, and the thread then exits. The same hooks and thread also serve the DT plant when its own gate is set; with neither gate set nothing here runs, exactly as alt-6. */
        bootargs_t0 = hv_bootargs_now();
        m.bootargs_fetch_hook = hv_bootargs_t1_fetch;
        m.bootargs_hvc_hook = hv_bootargs_t2_hvc;
        pthread_t pt;
        pthread_create(&pt, NULL, hv_bootargs_poll_thread, NULL);
    }
    return 0;
}

void hv_vm_destroy(void) {
    if (primary_started && !pthread_equal(primary_thread, pthread_self())) {
        pthread_join(primary_thread, NULL);
        primary_started = 0;
    }
    if (!machine_created) return;
    /* The bridge excludes readers. Unpublish the display before draining
       queued GPU work; completion callbacks still need the GIC and RAM. */
    os_unfair_lock_lock(&display_lock);
    atomic_store_explicit(&display_pvg, NULL, memory_order_release);
    os_unfair_lock_unlock(&display_lock);
    stop_pointer();
    hv_net_detach();
    net_on = 0;
    hv_audio_detach();
    hv_vmapple_destroy(&board);
    hv_disk_close(&disk);
    hv_disk_close(&aux);
    hv_machine_free(&m);
    memset(cpus, 0, sizeof cpus);
    ncpus = 0;
    boot_args_offset = 0;
    boot_last_scan = 0;
    extra_poll = NULL;
    machine_created = 0;
}

static void *kicker_thread(void *unused) {
    (void)unused;
    while (!atomic_load(&kicker_stopped)) {
        usleep(1000);
        hv_machine_kick_all(&m);
    }
    return NULL;
}

/* A thread that runs guest code. While a block runs its SP register holds the
   guest's SP, a guest address, so the kernel must never push a signal frame
   there: other threads take the asynchronous signals, and a handler that does
   run here (a fault) gets a stack of its own. */
static pthread_key_t stack_key;
static pthread_once_t stack_key_once = PTHREAD_ONCE_INIT;
static void free_cpu_stack(void *memory) {
    stack_t disabled = {.ss_flags = SS_DISABLE};
    sigaltstack(&disabled, NULL);
    free(memory);
}
static void make_stack_key(void) { pthread_key_create(&stack_key, free_cpu_stack); }

void hv_vm_prepare_cpu_thread(void) {
    static __thread int done;
    if (done) return;
    done = 1;
    if (hv_prof_register) hv_prof_register();
    stack_t ss = {.ss_sp = malloc(1u << 16), .ss_size = 1u << 16, .ss_flags = 0};
    if (ss.ss_sp) {
        sigaltstack(&ss, NULL);
        pthread_once(&stack_key_once, make_stack_key);
        pthread_setspecific(stack_key, ss.ss_sp);
    }
    sigset_t set;
    sigfillset(&set);
    sigdelset(&set, SIGSEGV), sigdelset(&set, SIGBUS), sigdelset(&set, SIGILL), sigdelset(&set, SIGTRAP), sigdelset(&set, SIGFPE);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
}

/* iOS parks default-QoS threads on efficiency cores readily; the guest's CPUs are what the user waits on. */
void hv_vm_cpu_qos(void) {
    hv_vm_prepare_cpu_thread();
    /* HV_QOS=ui|init|default (testing): the class the guest's CPUs run at. */
    const char *q = getenv("HV_QOS");
#if TARGET_OS_IPHONE
    qos_class_t c = QOS_CLASS_USER_INITIATED;
#else
    qos_class_t c = QOS_CLASS_DEFAULT;
#endif
    if (q && !strcmp(q, "ui")) c = QOS_CLASS_USER_INTERACTIVE;
    else if (q && !strcmp(q, "init")) c = QOS_CLASS_USER_INITIATED;
    else if (q && !strcmp(q, "default")) c = QOS_CLASS_DEFAULT;
    if (c != QOS_CLASS_DEFAULT) pthread_set_qos_class_self_np(c, 0);
}

/* CPUs 1 and up: run whenever PSCI CPU_ON starts them; the machine stops with CPU 0. */
static void *secondary_thread(void *arg) {
    HvCpu *c = arg;
    hv_vm_cpu_qos();
    int r = hv_run(c);
    if (!c->halted)
        fprintf(stderr, "hengevm: cpu %u stopped (%s) at pc %llx el%u\n", c->index, hv_vm_reason_name(r),
                (unsigned long long)c->pc, c->el);
    return NULL;
}

void hv_vm_flush_disks(void) {
    hv_disk_flush(&disk);
    hv_disk_flush(&aux);
}

int hv_vm_run_cpu0(void) {
    return hv_run(&cpus[0]);
}

static void *cpu0_thread(void *unused) {
    (void)unused;
    hv_vm_cpu_qos();
    int r = hv_vm_run_cpu0();
    /* Finish CPU activity before flushing or telling the UI the Mac stopped.
       CPU 0 can also leave for a fatal execution error. */
    hv_machine_halt(&m, HV_HALT_HOST);
    atomic_store(&kicker_stopped, 1);
    for (int i = 1; i < ncpus; i++)
        if (secondary_started[i]) pthread_join(secondary_threads[i], NULL);
    if (kicker_started) pthread_join(kicker, NULL);
    kicker_started = 0;
    memset(secondary_started, 0, sizeof secondary_started);
    /* A DMA worker can still be writing after the guest CPUs have exited. */
    hv_virtio_blk_stop(board.root_blk);
    hv_virtio_blk_stop(board.aux_blk);
    hv_audio_detach();
    hv_vm_flush_disks();
    if (exit_cb) exit_cb(r);
    return NULL;
}

int hv_vm_start(int cpu0, void (*on_exit)(int reason)) {
    exit_cb = on_exit;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8u << 20);
    atomic_store(&kicker_stopped, 0);
    /* Publish all join handles before CPU 0 can reach its exit callback. */
    for (int i = 1; i < ncpus; i++) {
        secondary_started[i] = pthread_create(&secondary_threads[i], &attr, secondary_thread, &cpus[i]) == 0;
        if (!secondary_started[i]) goto failed;
    }
    kicker_started = pthread_create(&kicker, NULL, kicker_thread, NULL) == 0;
    if (!kicker_started) goto failed;
    if (cpu0) {
        primary_started = pthread_create(&primary_thread, &attr, cpu0_thread, NULL) == 0;
        if (!primary_started) goto failed;
    }
    pthread_attr_destroy(&attr);
    return 0;
failed:
    pthread_attr_destroy(&attr);
    hv_machine_halt(&m, HV_HALT_HOST);
    atomic_store(&kicker_stopped, 1);
    for (int i = 1; i < ncpus; i++)
        if (secondary_started[i]) pthread_join(secondary_threads[i], NULL);
    memset(secondary_started, 0, sizeof secondary_started);
    if (kicker_started) pthread_join(kicker, NULL);
    kicker_started = 0;
    return -1;
}

void hv_vm_stop(void) {
    hv_machine_halt(&m, HV_HALT_HOST);
}

/* macOS's virtio mouse driver drops BTN_RIGHT, so the right button is a Control-click, with the right
   Control. The USB keyboard is read every 10 ms and the click goes over virtio, so Control goes down
   50 ms before the click and comes up 50 ms after it. The waits run on a serial queue that the pointer's
   moves and buttons all go through, so they stay in order and the caller (often the main thread) never
   waits. The guest's right Control and left button each have two owners, and stay down while either holds them. */
#define HID_RIGHT_CONTROL 0xe4
#define LINUX_KEY_RIGHTCTRL 97
static os_unfair_lock rctrl_lock = OS_UNFAIR_LOCK_INIT;
static int rctrl_user, rctrl_click;
static int left_user, left_click, left_sent; /* only the pointer queue touches these */

static dispatch_queue_t pointer_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("henge.pointer", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static void stop_pointer(void) {
    atomic_store(&input_stopping, 1);
    /* The bridge excludes new input. Finish a click already in progress and
       discard queued input before releasing the keyboard and mouse. */
    dispatch_sync(pointer_queue(), ^{
        left_user = left_click = left_sent = 0;
        os_unfair_lock_lock(&rctrl_lock);
        rctrl_user = rctrl_click = 0;
        os_unfair_lock_unlock(&rctrl_lock);
    });
}

static void rctrl_hold(int *owner, int down) {
    os_unfair_lock_lock(&rctrl_lock);
    *owner = down;
    hv_xhci_key(board.usb, HID_RIGHT_CONTROL, rctrl_user || rctrl_click);
    os_unfair_lock_unlock(&rctrl_lock);
}

void hv_vm_key(uint16_t code, int down) {
    if (code == LINUX_KEY_RIGHTCTRL) rctrl_hold(&rctrl_user, down);
    else hv_xhci_key_linux(board.usb, code, down);
}

void hv_vm_key_hid(uint8_t usage, int down) {
    if (usage == HID_RIGHT_CONTROL) rctrl_hold(&rctrl_user, down);
    else hv_xhci_key(board.usb, usage, down);
}

static void move_now(void *ctx) {
    if (atomic_load(&input_stopping)) return;
    int64_t packed = (int64_t)(intptr_t)ctx;
    int32_t dx = (int32_t)(packed >> 32), dy = (int32_t)packed;
    if (dx) hv_virtio_input_send(board.mouse, HV_EV_REL, HV_REL_X, dx);
    if (dy) hv_virtio_input_send(board.mouse, HV_EV_REL, HV_REL_Y, dy);
    hv_virtio_input_send(board.mouse, HV_EV_SYN, 0, 0);
}

void hv_vm_mouse_move(int dx, int dy) {
    int64_t packed = (int64_t)((uint64_t)(uint32_t)dx << 32 | (uint32_t)dy);
    dispatch_async_f(pointer_queue(), (void *)(intptr_t)packed, move_now);
}

static void left_update(void) {
    int down = left_user || left_click;
    if (down == left_sent) return;
    left_sent = down;
    hv_virtio_input_send(board.mouse, HV_EV_KEY, HV_BTN_LEFT, down);
    hv_virtio_input_send(board.mouse, HV_EV_SYN, 0, 0);
}

static void button_now(void *ctx) {
    if (atomic_load(&input_stopping)) return;
    intptr_t v = (intptr_t)ctx;
    int button = (int)(v >> 1), down = (int)(v & 1);
    if (button == 0) {
        left_user = down;
        left_update();
    } else if (button == 1 && down != left_click) {
        if (down) {
            rctrl_hold(&rctrl_click, 1);
            usleep(50000);
        }
        left_click = down;
        left_update();
        if (!down) {
            usleep(50000);
            rctrl_hold(&rctrl_click, 0);
        }
    } else if (button == 2) {
        hv_virtio_input_send(board.mouse, HV_EV_KEY, HV_BTN_MIDDLE, down);
        hv_virtio_input_send(board.mouse, HV_EV_SYN, 0, 0);
    }
}

void hv_vm_mouse_button(int button, int down) {
    if (button < 0 || button > 2) return;
    dispatch_async_f(pointer_queue(), (void *)(intptr_t)(button << 1 | !!down), button_now);
}

/* The guest takes a wheel event as 8 bits: -200 arrives as +56, the wrong way. So big moves go in pieces. */
static void wheel(uint16_t axis, int amount) {
    while (amount) {
        int piece = amount > 100 ? 100 : amount < -100 ? -100 : amount;
        hv_virtio_input_send(board.mouse, HV_EV_REL, axis, piece);
        hv_virtio_input_send(board.mouse, HV_EV_SYN, 0, 0);
        amount -= piece;
    }
}

void hv_vm_mouse_wheel(int dy) { wheel(HV_REL_WHEEL, dy); }
void hv_vm_mouse_hwheel(int dx) { wheel(HV_REL_HWHEEL, dx); }

void hv_vm_touch(int id, int phase, int x, int y, uint32_t ts_ms) {
    if (x < 0) x = 0;
    if (x > HV_TP_SENSOR_X) x = HV_TP_SENSOR_X;
    if (y < 0) y = 0;
    if (y > HV_TP_SENSOR_Y) y = HV_TP_SENSOR_Y;
    hv_xhci_touch(board.usb, id, phase, x, y, ts_ms);
}

void hv_vm_touch_frame(uint32_t ts_ms) { hv_xhci_touch_frame(board.usb, ts_ms); }

void hv_vm_touch_button(int down) { hv_xhci_touch_button(board.usb, down); }

int hv_vm_pointer(int *x, int *y) {
    HvPvgLite *pvg = atomic_load_explicit(&display_pvg, memory_order_acquire);
    const uint8_t *page = pvg ? hv_pvg_lite_display_page(pvg) : NULL;
    if (!page) return -1;
    uint32_t at = *(const volatile uint32_t *)(page + 0xe00);
    if (at == 0xffffffff) return -1;
    *x = (int)(at & 0xffff), *y = (int)(at >> 16);
    return 0;
}

int hv_vm_snapshot(uint8_t *bgra, int width, int height) {
    HvPvgLite *pvg = atomic_load_explicit(&display_pvg, memory_order_acquire);
    if (!pvg || width <= 0 || height <= 0) return -1;
    return hv_pvg_lite_snapshot(pvg, bgra, (uint32_t)width, (uint32_t)height);
}
