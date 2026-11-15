#include "timer.h"

#include "sysreg.h"

static uint64_t one(int *line, uint64_t ctl, uint64_t cval, uint64_t now, uint64_t offset) {
    int enabled = (ctl & 1) && !(ctl & 2);
    int fired = enabled && now - offset >= cval;
    *line = fired;
    /* Deadline in host counter units; nothing to wait for if off or already firing. */
    return enabled && !fired ? cval + offset : 0;
}

uint64_t hv_timer_update(HvGic *g, HvCpu *cpu) {
    uint64_t now = hv_counter();
    int virtual_line, physical_line;
    uint64_t v = one(&virtual_line, cpu->cntv_ctl, cpu->cntv_cval, now, cpu->cntvoff);
    uint64_t p = one(&physical_line, cpu->cntp_ctl, cpu->cntp_cval, now, 0);
    hv_gicv3_set_timer_lines(g, (int)cpu->index, virtual_line, physical_line);
    if (!v) return p;
    if (!p) return v;
    return v < p ? v : p;
}
