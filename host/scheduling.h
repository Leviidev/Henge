#ifndef HENGE_SCHEDULING_H
#define HENGE_SCHEDULING_H
#include "scheduling_policy.h"
#ifdef __cplusplus
extern "C" {
#endif
const HvHostCpuInfo *hv_host_cpu_info(void);
const char *hv_host_model(void);
const char *hv_host_chip(void);
const char *hv_host_layout_source(void);
int hv_host_performance_cores(void);
int hv_host_efficiency_cores(void);
int hv_host_is_duo(void);
int hv_host_is_m4_16gb(void);
void hv_host_log_capabilities(void);
HvSchedulePlan hv_schedule_read(int vcpus);
const char *hv_schedule_qos_name(HvHostQos qos);
void hv_schedule_log_plan(const HvSchedulePlan *plan);
/* Only call at a host worker's entry, before guest SIMD/SP state is live.
   Setting QoS is a scheduler hint, not core affinity. Returns a POSIX error. */
int hv_schedule_apply(HvHostRole role, unsigned index, const HvSchedulePlan *plan, int log);
void hv_schedule_aux_start(HvHostRole role);
#ifdef __cplusplus
}
#endif
#endif
