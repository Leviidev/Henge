#include "scheduling.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/utsname.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <pthread/qos.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>
#endif

static pthread_once_t info_once = PTHREAD_ONCE_INIT;
static HvHostCpuInfo info;
#if defined(__APPLE__)
static int sys_int(const char *name) {
    int n=0; size_t size=sizeof n;
    return sysctlbyname(name,&n,&size,NULL,0)==0 && size==sizeof n && n>0 && n<=256 ? n : 0;
}
#endif
static void detect(void) {
    struct utsname u;
    if (!uname(&u)) snprintf(info.model,sizeof info.model,"%.*s",(int)sizeof info.model-1,u.machine);
#if defined(__APPLE__)
    info.ios = TARGET_OS_IPHONE;
    info.simulator = TARGET_OS_SIMULATOR;
    info.total=sys_int("hw.logicalcpu_max");
    if (!info.total) info.total=sys_int("hw.logicalcpu");
    info.active=sys_int("hw.logicalcpu");
    info.performance=sys_int("hw.perflevel0.logicalcpu");
    info.efficiency=sys_int("hw.perflevel1.logicalcpu");
    size_t memory_size = sizeof info.physical_memory;
    if (sysctlbyname("hw.memsize", &info.physical_memory, &memory_size, NULL, 0) || memory_size != sizeof info.physical_memory)
        info.physical_memory = 0;
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase)==KERN_SUCCESS) {
        info.timebase_numer=timebase.numer; info.timebase_denom=timebase.denom;
    }
#else
    long total=sysconf(_SC_NPROCESSORS_CONF), active=sysconf(_SC_NPROCESSORS_ONLN);
    info.total=total>0 && total<=256 ? (int)total : 0;
    info.active=active>0 && active<=256 ? (int)active : 0;
#endif
    hv_schedule_validate_topology(&info);
}
const HvHostCpuInfo *hv_host_cpu_info(void) {pthread_once(&info_once,detect); return &info;}
const char *hv_host_model(void) {return hv_host_cpu_info()->model;}
const char *hv_host_chip(void) {
    const HvHostCpuInfo *h=hv_host_cpu_info();
    if (h->duo) return "A20 Pro (Duo model profile)";
    if (h->ios && !strcmp(h->model,"iPad16,5")) return "M4 (iPad model profile)";
    return "Not classified";
}
const char *hv_host_layout_source(void) {
    switch (hv_host_cpu_info()->layout) {
    case HV_LAYOUT_RUNTIME:return "runtime sysctl";
    case HV_LAYOUT_MODEL:return "Apple specification fallback";
    default:return "unavailable";
    }
}
int hv_host_performance_cores(void) {return hv_host_cpu_info()->performance;}
int hv_host_efficiency_cores(void) {return hv_host_cpu_info()->efficiency;}
int hv_host_is_duo(void) {return hv_host_cpu_info()->duo;}
int hv_host_is_m4_16gb(void) {return hv_host_cpu_info()->m4_16gb;}
void hv_host_log_capabilities(void) {
    const HvHostCpuInfo *h=hv_host_cpu_info();
    fprintf(stderr,"host-capabilities: model=%s chip=%s logical=%d active=%d P=%d E=%d layout=%s timebase=%u/%u ns (core placement controlled by OS; no energy measurement)\n",
        h->model,hv_host_chip(),h->total,h->active,h->performance,h->efficiency,hv_host_layout_source(),h->timebase_numer,h->timebase_denom);
}
HvSchedulePlan hv_schedule_read(int vcpus) {
    return hv_schedule_plan(hv_host_cpu_info(),vcpus,getenv("HV_CPU_POLICY"),getenv("HV_QOS"));
}
const char *hv_schedule_qos_name(HvHostQos qos) {
    switch(qos) {
    case HV_QOS_DEFAULT:return "default";
    case HV_QOS_INITIATED:return "user-initiated";
    case HV_QOS_INTERACTIVE:return "user-interactive";
    case HV_QOS_UTILITY:return "utility";
    default:return "inherited";
    }
}
void hv_schedule_log_plan(const HvSchedulePlan *p) {
    const char *mode=p->mode==HV_SCHED_AUTO ? "auto" : p->mode==HV_SCHED_MIXED ? "mixed" : "legacy";
    int utility=0, inherited=0;
    for(int i=0;i<p->vcpus;i++) {
        HvHostQos q=hv_schedule_role(p,HV_ROLE_CPU,(unsigned)i);
        utility+=q==HV_QOS_UTILITY; inherited+=q==HV_QOS_INHERIT;
    }
    fprintf(stderr,"host-scheduling: policy=%s vcpus=%d responsive_requests=%d utility_requests=%d inherited_requests=%d override=%s reason=%s (QoS hints; no pinning; guest CPU count/Retina/refresh/timers unchanged)\n",
        mode,p->vcpus,p->vcpus-utility-inherited,utility,inherited,hv_schedule_qos_name(p->override),p->reason);
}
int hv_schedule_apply(HvHostRole role, unsigned index, const HvSchedulePlan *p, int log) {
    const char *name;
    switch(role) {
    case HV_ROLE_CPU:name="vCPU";break;
    case HV_ROLE_TICKER:name="timer wake";break;
    case HV_ROLE_NETWORK:name="network";break;
    case HV_ROLE_SHARE_IO:name="shared file I/O";break;
    case HV_ROLE_SHARE_LISTENER:name="share listener";break;
    case HV_ROLE_PROFILER:name="diagnostic sampler";break;
    default:name="USB diagnostic";break;
    }
    HvHostQos want=hv_schedule_role(p,role,index);
    int rc=0;
#if defined(__APPLE__)
    char label[64];snprintf(label,sizeof label,"Henge %s %u",name,index);pthread_setname_np(label);
    qos_class_t q=QOS_CLASS_UNSPECIFIED, actual=QOS_CLASS_UNSPECIFIED; int relative=0;
    switch(want) {
    case HV_QOS_DEFAULT:q=QOS_CLASS_DEFAULT;break;
    case HV_QOS_INITIATED:q=QOS_CLASS_USER_INITIATED;break;
    case HV_QOS_INTERACTIVE:q=QOS_CLASS_USER_INTERACTIVE;break;
    case HV_QOS_UTILITY:q=QOS_CLASS_UTILITY;break;
    default:break;
    }
    /* Explicit DEFAULT must clear an inherited high class, too. */
    if (want!=HV_QOS_INHERIT) rc=pthread_set_qos_class_self_np(q,0);
    int readback=pthread_get_qos_class_np(pthread_self(),&actual,&relative);
    if (log || rc) fprintf(stderr,"host-qos: role=%s index=%u requested=%s result=%d readback_result=%d qos=%#x (not a core residency measurement)\n",
        name,index,hv_schedule_qos_name(want),rc,readback,(unsigned)actual);
#else
    if (want!=HV_QOS_INHERIT) rc=ENOTSUP;
    if (log) fprintf(stderr,"host-qos: role=%s index=%u requested=%s result=%d (platform has no Apple QoS)\n",name,index,hv_schedule_qos_name(want),rc);
#endif
    return rc;
}
void hv_schedule_aux_start(HvHostRole role) {
    HvSchedulePlan plan=hv_schedule_read(0);
    hv_schedule_apply(role,0,&plan,1);
}
