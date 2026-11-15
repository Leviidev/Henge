#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1 /* Public Darwin QoS declarations alongside POSIX APIs. */
#endif
#include "scheduling.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif

static HvHostCpuInfo duo(void) {
    HvHostCpuInfo h={.model="iPhone19,4",.ios=1,.total=6,.active=6};
    hv_schedule_validate_topology(&h); return h;
}
static void decisions(void) {
    HvHostCpuInfo h=duo();
    assert(h.duo && h.layout==HV_LAYOUT_MODEL && h.performance==2 && h.efficiency==4);
    h.performance=2; h.efficiency=4; hv_schedule_validate_topology(&h);
    assert(h.layout==HV_LAYOUT_RUNTIME);
    HvSchedulePlan p=hv_schedule_plan(&h,6,NULL,NULL);
    assert(p.mode==HV_SCHED_AUTO && !p.mixed && p.fast_vcpus==6);
    for(unsigned i=0;i<6;i++) assert(hv_schedule_role(&p,HV_ROLE_CPU,i)==HV_QOS_INITIATED);
    assert(hv_schedule_role(&p,HV_ROLE_PROFILER,0)==HV_QOS_UTILITY);
    assert(hv_schedule_role(&p,HV_ROLE_SHARE_LISTENER,0)==HV_QOS_INHERIT);
    assert(hv_schedule_role(&p,HV_ROLE_USB_PROBE,0)==HV_QOS_UTILITY);
    assert(hv_schedule_role(&p,HV_ROLE_SHARE_IO,0)==HV_QOS_INHERIT);
    assert(hv_schedule_role(&p,HV_ROLE_TICKER,0)==HV_QOS_INHERIT);
    assert(hv_schedule_role(&p,HV_ROLE_NETWORK,0)==HV_QOS_INHERIT);
    p=hv_schedule_plan(&h,6,"legacy",NULL);
    for(int r=HV_ROLE_TICKER;r<=HV_ROLE_USB_PROBE;r++) assert(hv_schedule_role(&p,(HvHostRole)r,0)==HV_QOS_INHERIT);
    for(int n=1;n<=16;n++) {
        p=hv_schedule_plan(&h,n,"mixed",NULL);
        assert(p.mixed==(n>2));
        for(unsigned i=0;i<(unsigned)n;i++)
            assert(hv_schedule_role(&p,HV_ROLE_CPU,i)==(i<2?HV_QOS_INITIATED:HV_QOS_UTILITY));
        assert(hv_schedule_role(&p,HV_ROLE_CPU,99)==HV_QOS_INITIATED);
        assert(hv_schedule_role(&p,HV_ROLE_TICKER,0)!=HV_QOS_UTILITY);
        assert(hv_schedule_role(&p,HV_ROLE_NETWORK,0)!=HV_QOS_UTILITY);
    }
    const char *overrides[]={"ui","init","default","utility"};
    HvHostQos wants[]={HV_QOS_INTERACTIVE,HV_QOS_INITIATED,HV_QOS_DEFAULT,HV_QOS_UTILITY};
    for(unsigned j=0;j<4;j++) {
        p=hv_schedule_plan(&h,6,"mixed",overrides[j]);assert(!p.mixed);
        for(unsigned i=0;i<6;i++)assert(hv_schedule_role(&p,HV_ROLE_CPU,i)==wants[j]);
    }
    p=hv_schedule_plan(&h,6,"typo",NULL);assert(p.mode==HV_SCHED_LEGACY && !p.mixed);
    h.active=2;p=hv_schedule_plan(&h,6,"mixed",NULL);assert(!p.mixed);
    h.active=0;p=hv_schedule_plan(&h,6,"mixed",NULL);assert(!p.mixed);
    h.active=99;p=hv_schedule_plan(&h,6,"mixed",NULL);assert(!p.mixed);
    h=duo();h.simulator=1;hv_schedule_validate_topology(&h);assert(!h.duo);
    p=hv_schedule_plan(&h,6,"mixed",NULL);assert(!p.mixed);
    h=duo();h.total=8;h.performance=0;h.efficiency=0;hv_schedule_validate_topology(&h);
    assert(h.layout==HV_LAYOUT_UNKNOWN && !h.performance && !h.efficiency);
    p=hv_schedule_plan(&h,6,"mixed",NULL);assert(!p.mixed);
    h=(HvHostCpuInfo){.model="iPad16,5",.ios=1,.total=10,.active=10,.performance=4,.efficiency=6};
    hv_schedule_validate_topology(&h);assert(!h.duo && h.layout==HV_LAYOUT_RUNTIME);
    assert(!h.m4_16gb); /* Missing memory evidence cannot activate the profile. */
    h.physical_memory=16ull<<30;hv_schedule_validate_topology(&h);assert(h.m4_16gb);
    h.physical_memory=8ull<<30;hv_schedule_validate_topology(&h);assert(!h.m4_16gb);
    h.total=9;h.performance=3;h.efficiency=6;hv_schedule_validate_topology(&h);assert(!h.m4_16gb);
    h.total=10;h.active=10;h.performance=0;h.efficiency=0;h.physical_memory=16ull<<30;
    hv_schedule_validate_topology(&h);assert(h.m4_16gb && h.layout==HV_LAYOUT_MODEL && h.performance==4 && h.efficiency==6);
    h.simulator=1;hv_schedule_validate_topology(&h);assert(!h.m4_16gb && !h.duo);
    h.simulator=0;hv_schedule_validate_topology(&h);assert(h.m4_16gb);
    p=hv_schedule_plan(&h,6,"mixed",NULL);assert(!p.mixed);
    h=(HvHostCpuInfo){.model="unknown",.ios=1,.total=6,.active=6};
    hv_schedule_validate_topology(&h);assert(h.layout==HV_LAYOUT_UNKNOWN && !h.duo);
    p=hv_schedule_plan(&h,6,"mixed",NULL);assert(!p.mixed);
    h=duo();h.ios=0;hv_schedule_validate_topology(&h);
    p=hv_schedule_plan(&h,6,"auto",NULL);
    assert(!p.mixed && hv_schedule_role(&p,HV_ROLE_CPU,0)==HV_QOS_INHERIT);
    assert(hv_schedule_role(&p,HV_ROLE_PROFILER,0)==HV_QOS_INHERIT);
}
static const HvHostCpuInfo *observed;
static void *read_info(void *unused) {
    (void)unused;
    for(int i=0;i<1000;i++) {
        const HvHostCpuInfo *h=hv_host_cpu_info();assert(h==observed && h->model[0]);
        assert(!strcmp(hv_host_model(),h->model));
        assert(hv_host_performance_cores()==h->performance && hv_host_efficiency_cores()==h->efficiency);
    }
    return NULL;
}
static void *apply_qos(void *unused) {
    (void)unused;
    HvHostCpuInfo h=duo();HvSchedulePlan p=hv_schedule_plan(&h,6,"auto",NULL);
#if defined(__APPLE__)
    qos_class_t q;int rel;
    assert(hv_schedule_apply(HV_ROLE_CPU,0,&p,1)==0);
    assert(!pthread_get_qos_class_np(pthread_self(),&q,&rel) && q==QOS_CLASS_USER_INITIATED);
    assert(hv_schedule_apply(HV_ROLE_PROFILER,0,&p,1)==0);
    assert(!pthread_get_qos_class_np(pthread_self(),&q,&rel) && q==QOS_CLASS_UTILITY);
    assert(hv_schedule_apply(HV_ROLE_CPU,0,&p,1)==0);
    assert(!pthread_get_qos_class_np(pthread_self(),&q,&rel) && q==QOS_CLASS_USER_INITIATED);
    p=hv_schedule_plan(&h,6,"auto","default");
    assert(hv_schedule_apply(HV_ROLE_CPU,0,&p,1)==0);
    assert(!pthread_get_qos_class_np(pthread_self(),&q,&rel) && q==QOS_CLASS_DEFAULT);
    puts("PASS native QoS: requested classes read back; responsive CPU class restored; DEFAULT clears inherited high class (not P/E residency proof)");
#else
    assert(hv_schedule_apply(HV_ROLE_CPU,0,&p,0)==ENOTSUP);
    puts("NOT VERIFIED native Apple QoS on this platform");
#endif
    return NULL;
}
int main(void) {
    decisions();
    observed=hv_host_cpu_info();
    pthread_t threads[16];
    for(int i=0;i<16;i++)assert(!pthread_create(&threads[i],NULL,read_info,NULL));
    for(int i=0;i<16;i++)assert(!pthread_join(threads[i],NULL));
    /* Environment policy is a fresh snapshot, not cached across launches. */
    setenv("HV_CPU_POLICY","mixed",1);setenv("HV_QOS","ui",1);
    HvSchedulePlan p=hv_schedule_read(6);assert(p.override==HV_QOS_INTERACTIVE);
    setenv("HV_CPU_POLICY","auto",1);unsetenv("HV_QOS");p=hv_schedule_read(6);
    assert(p.mode==HV_SCHED_AUTO && !p.override && !p.mixed);
    assert(!pthread_create(&threads[0],NULL,apply_qos,NULL));assert(!pthread_join(threads[0],NULL));
    hv_host_log_capabilities();hv_schedule_log_plan(&p);
    puts("PASS scheduling: Duo model/runtime topology, unknown/simulator/M4 fallback, all CPU counts, protected roles, env precedence/reset and concurrent metadata reads");
}
