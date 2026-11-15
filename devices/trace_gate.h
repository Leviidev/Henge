#ifndef HENGE_TRACE_GATE_H
#define HENGE_TRACE_GATE_H
#include <stdint.h>
#include <unistd.h>

/* Owned by the GPU's serial worker. No timer or wakeups when the GPU is idle.
   Changes to the debug flag take effect on a command at most one second later. */
typedef struct HvTraceGate {
    double next_check;
    uint64_t probes, cached;
    int checked, enabled;
} HvTraceGate;

static inline int hv_trace_file_enabled(HvTraceGate *gate, const char *path, double now) {
    if (!path) return 0;
    if (!gate->checked || now >= gate->next_check) {
        gate->enabled = access(path, F_OK) == 0;
        gate->checked = 1;
        gate->next_check = now + 1.0;
        gate->probes++;
    } else {
        gate->cached++;
    }
    return gate->enabled;
}
#endif
