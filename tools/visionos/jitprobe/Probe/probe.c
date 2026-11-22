#include "Probe.h"
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <os/log.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <unistd.h>

extern void *probe_brk_get_jit_mapping(void *addr, size_t len);
extern void probe_brk_jit_detach(void);
extern uint64_t probe_brk_probe(void);
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#define REGION (16u << 20)
static char report[8192];
static size_t used;

static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    os_log(OS_LOG_DEFAULT, "JITPROBE %{public}s", line);
    used += snprintf(report + used, sizeof report - used, "%s\n", line);
}

/* A brk nobody services: skip it and return 0 instead of dying. */
static void on_trap(int sig, siginfo_t *info, void *uc_) {
    (void)sig; (void)info;
    ucontext_t *uc = uc_;
    uc->uc_mcontext->__ss.__x[0] = 0;
    uc->uc_mcontext->__ss.__pc += 4;
}

int probe_debugged(void) {
    uint32_t flags = 0;
    csops(getpid(), 0, &flags, sizeof flags);
    return (flags & 0x10000000) != 0; /* CS_DEBUGGED */
}

static int call(uint8_t *rx, uint8_t *rw, size_t off, uint16_t value) {
    uint32_t code[2] = { 0x52800000u | ((uint32_t)value << 5), 0xD65F03C0u }; /* movz w0, #value ; ret */
    memcpy(rw + off, code, sizeof code);
    sys_icache_invalidate(rx + off, sizeof code);
    return ((int (*)(void))(void *)(rx + off))();
}

const char *probe_run(void) {
    used = 0;
    struct sigaction sa = { 0 };
    sa.sa_sigaction = on_trap;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGTRAP, &sa, NULL);

    say("1. waiting for a debugger (CS_DEBUGGED)...");
    while (!probe_debugged()) usleep(100 * 1000);
    say("   debugger attached");

    uint64_t p = probe_brk_probe();
    say("2. brk #0x69 probe: %#llx (%s)", p, p == 0xE0000069 ? "serviced" : "NOT serviced");

    uint8_t *rx = probe_brk_get_jit_mapping(NULL, REGION);
    say("3. brk #0xf00d prepare region (%u MB): rx=%p", REGION >> 20, rx);
    if (!rx) { say("FAIL: no region"); return report; }

    vm_address_t rw = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, REGION, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
    say("4. vm_remap writable alias: kr=%d rw=%p cur=%#x max=%#x", kr, (void *)rw, cur, max);
    if (kr != KERN_SUCCESS) { say("FAIL: no alias"); return report; }
    kr = vm_protect(mach_task_self(), rw, REGION, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    say("   vm_protect alias RW: kr=%d", kr);
    if (kr != KERN_SUCCESS) { say("FAIL: alias not writable"); return report; }

    say("5. calling generated code, first page...");
    int a = call(rx, (uint8_t *)rw, 0, 42);
    say("   returned %d (%s)", a, a == 42 ? "PASS" : "FAIL");
    int b = call(rx, (uint8_t *)rw, REGION - 16384, 43);
    say("   last page returned %d (%s)", b, b == 43 ? "PASS" : "FAIL");
    int c = call(rx, (uint8_t *)rw, 0, 44);
    say("   rewritten first page returned %d (%s)", c, c == 44 ? "PASS" : "FAIL");

    say("6. detaching the debugger (brk #0xf00d, x16=0)");
    probe_brk_jit_detach();
    for (int i = 0; i < 50 && probe_debugged(); i++) usleep(100 * 1000);
    say("   CS_DEBUGGED after detach: %d", probe_debugged());

    say("7. new code after detach...");
    int d = call(rx, (uint8_t *)rw, 8 * 16384, 45);
    say("   returned %d (%s)", d, d == 45 ? "PASS" : "FAIL");
    /* Every page of the region, at a different offset in each: one the debugger missed would fault here. */
    size_t pages = REGION / 16384, bad = 0;
    for (size_t page = 0; page < pages; page++) {
        size_t off = page * 16384 + (page * 64) % (16384 - 8);
        off &= ~(size_t)3;
        if (call(rx, (uint8_t *)rw, off, (uint16_t)(page & 0xffff)) != (int)(page & 0xffff)) bad++;
    }
    say("8. code in all %zu pages: %zu wrong (%s)", pages, bad, bad ? "FAIL" : "PASS");
    int ok = a == 42 && b == 43 && c == 44 && d == 45 && bad == 0;
    say("%s", ok ? "RESULT: JIT WORKS ON THIS DEVICE" : "RESULT: FAILED");
    return report;
}
