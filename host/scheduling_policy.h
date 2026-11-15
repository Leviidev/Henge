#ifndef HENGE_SCHEDULING_POLICY_H
#define HENGE_SCHEDULING_POLICY_H

#include <string.h>
#include <stdint.h>

/* Pure policy: no timers, private APIs, affinity, or guest-thread guesses. */
typedef enum { HV_SCHED_AUTO, HV_SCHED_LEGACY, HV_SCHED_MIXED } HvScheduleMode;
typedef enum { HV_QOS_INHERIT, HV_QOS_DEFAULT, HV_QOS_INITIATED, HV_QOS_INTERACTIVE, HV_QOS_UTILITY } HvHostQos;
typedef enum { HV_ROLE_CPU, HV_ROLE_TICKER, HV_ROLE_NETWORK, HV_ROLE_SHARE_IO,
               HV_ROLE_SHARE_LISTENER, HV_ROLE_PROFILER, HV_ROLE_USB_PROBE } HvHostRole;
typedef enum { HV_LAYOUT_UNKNOWN, HV_LAYOUT_RUNTIME, HV_LAYOUT_MODEL } HvLayoutSource;

typedef struct {
    char model[64];
    int ios, simulator, total, active, performance, efficiency, duo, m4_16gb;
    uint64_t physical_memory;
    HvLayoutSource layout;
    unsigned timebase_numer, timebase_denom;
} HvHostCpuInfo;

static inline void hv_schedule_validate_topology(HvHostCpuInfo *h) {
    h->duo = h->ios && !h->simulator && !strcmp(h->model, "iPhone19,4");
    h->layout = HV_LAYOUT_UNKNOWN;
    if (h->total > 0 && h->total <= 256 && h->performance > 0 && h->efficiency > 0 &&
        h->performance <= h->total && h->efficiency == h->total - h->performance) {
        h->layout = HV_LAYOUT_RUNTIME;
    } else {
        h->performance = h->efficiency = 0;
        /* Apple documents A20 Pro's 2+4 layout. Model is observed in the user's
           Duo log. This fallback is explicitly labelled, never a runtime measurement. */
        if (h->duo && h->total == 6) {
            h->performance = 2; h->efficiency = 4; h->layout = HV_LAYOUT_MODEL;
        }
        if (h->ios && !h->simulator && !strcmp(h->model, "iPad16,5") && h->total == 10 &&
            h->physical_memory >= (14ull << 30)) {
            h->performance = 4; h->efficiency = 6; h->layout = HV_LAYOUT_MODEL;
        }
    }
    /* The identifier alone also covers lower-memory configurations. Never
       infer the ten-core/16GB profile from the model string alone. */
    h->m4_16gb = h->ios && !h->simulator && !strcmp(h->model, "iPad16,5") &&
        h->total == 10 && h->performance == 4 && h->efficiency == 6 && h->physical_memory >= (14ull << 30);
}

typedef struct {
    HvScheduleMode mode;
    HvHostQos base, override;
    int vcpus, fast_vcpus, mixed, ios;
    const char *reason;
} HvSchedulePlan;

static inline HvSchedulePlan hv_schedule_plan(const HvHostCpuInfo *h, int vcpus,
                                             const char *mode, const char *override) {
    HvSchedulePlan p = {.mode=HV_SCHED_AUTO, .base=h->ios ? HV_QOS_INITIATED : HV_QOS_INHERIT,
                        .vcpus=vcpus, .fast_vcpus=vcpus, .ios=h->ios, .reason="critical-work-preserved"};
    if (mode && !strcmp(mode, "legacy")) p.mode = HV_SCHED_LEGACY;
    else if (mode && !strcmp(mode, "mixed")) p.mode = HV_SCHED_MIXED;
    else if (mode && strcmp(mode, "auto")) {p.mode=HV_SCHED_LEGACY; p.reason="invalid-policy-legacy-fallback";}
    if (override) {
        if (!strcmp(override,"ui")) p.override=HV_QOS_INTERACTIVE;
        else if (!strcmp(override,"init")) p.override=HV_QOS_INITIATED;
        else if (!strcmp(override,"default")) p.override=HV_QOS_DEFAULT;
        else if (!strcmp(override,"utility")) p.override=HV_QOS_UTILITY;
    }
    if (p.mode == HV_SCHED_MIXED) {
        if (p.override) p.reason="HV_QOS-overrides-mixed";
        else if (!h->duo || h->layout == HV_LAYOUT_UNKNOWN) p.reason="mixed-unavailable-on-this-host";
        else if (h->active <= h->performance || h->active > h->total) p.reason="mixed-unavailable-active-core-count";
        else if (vcpus <= h->performance) p.reason="no-extra-vcpus-to-classify";
        else {p.mixed=1; p.fast_vcpus=h->performance; p.reason="experimental-vcpu-split-not-guest-worker-affinity";}
    }
    return p;
}

static inline HvHostQos hv_schedule_role(const HvSchedulePlan *p, HvHostRole role, unsigned index) {
    if (role == HV_ROLE_CPU) {
        if (p->override) return p->override;
        return p->mixed && index < (unsigned)p->vcpus && index >= (unsigned)p->fast_vcpus ? HV_QOS_UTILITY : p->base;
    }
    if (p->mode == HV_SCHED_LEGACY || !p->ios) return HV_QOS_INHERIT;
    /* No timer, networking, shared-file I/O, input, audio or GPU demotion. */
    if (role == HV_ROLE_PROFILER || role == HV_ROLE_USB_PROBE) return HV_QOS_UTILITY;
    /* Accepting a shared-file request is latency-sensitive, too. Never lower
       its listener merely because it spends most of its time asleep. */
    return HV_QOS_INHERIT;
}
#endif
