// SPDX-License-Identifier: GPL-2.0-or-later
/* Linux host (tools/hengelinux, tests only): no EL0 window (core/window.c maps guest pages with Mach calls).
   The knob reads as off, so the translator never emits windowed accesses. */
#include "window.h"

int hv_window_enabled(void) { return 0; }
int hv_window_reserve(struct HvMachine *m, int ncpus) { (void)m, (void)ncpus; return 0; }
int hv_window_attach(HvCpu *cpu) { (void)cpu; return 0; }
void hv_window_detach(HvCpu *cpu) { (void)cpu; }
void hv_window_drop_all(HvCpu *cpu) { (void)cpu; }
void hv_window_drop_except(HvCpu *cpu, uint64_t lo, const uint64_t *keep, uint32_t nchunks) {
    (void)cpu, (void)lo, (void)keep, (void)nchunks;
}
void hv_window_drop_range(HvCpu *cpu, uint64_t va, uint64_t len) { (void)cpu, (void)va, (void)len; }
void hv_window_protect(HvCpu *cpu, const uint8_t *host_page) { (void)cpu, (void)host_page; }
int hv_window_signal(struct HvMachine *m, siginfo_t *info, void *ctx) { (void)m, (void)info, (void)ctx; return 0; }
