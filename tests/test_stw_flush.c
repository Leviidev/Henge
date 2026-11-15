#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1
#include "machine.h"
#include "dispatch.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static HvMachine m;
static HvCpu cpus[6];
static uint32_t code[32768] __attribute__((aligned(16384)));
static void *run_cpu(void *arg){HvCpu *c=arg;assert(hv_run(c)==HV_EXIT_HALT);return NULL;}
int main(void) {
    alarm(40);
    /* This fixture specifically tests full reset. Partial reuse is exercised
       independently by the four-vCPU cross-page test_jit_ring. */
    setenv("HV_JIT_SEGMENTS","1",1);
    unsigned ipi=getenv("HV_STW_IPI")!=NULL, expected=0;
    for(unsigned i=0;i<sizeof code/sizeof code[0];i++) {
        int tlbi=ipi && (i%1024==1023);
        code[i]=tlbi?0xd508831fu:0x91000400u; /* TLBI VMALLE1IS / ADD X0,X0,#1 */
        expected+=!tlbi;
    }
    for(unsigned event=0;event<2;event++) {
        setenv("HV_STW_WAIT",event?"1":"0",1);
        assert(!hv_machine_init(&m,64<<10));
        assert(!hv_machine_add_ram(&m,(uintptr_t)code,sizeof code,code,1));
        m.stop_pc=(uintptr_t)(code+sizeof code/sizeof code[0]);
        for(unsigned i=0;i<6;i++){hv_cpu_reset_index(&cpus[i],&m,i);cpus[i].pc=(uintptr_t)code;}
        pthread_t ts[6];
        for(unsigned i=0;i<6;i++)assert(!pthread_create(&ts[i],NULL,run_cpu,&cpus[i]));
        for(unsigned i=0;i<6;i++)assert(!pthread_join(ts[i],NULL));
        for(unsigned i=0;i<6;i++)assert(cpus[i].x[0]==expected);
        assert(m.stats.block_flushes>0 && !atomic_load(&m.quiesce.waiters) && !atomic_load(&m.quiesce.errors));
        uint64_t posted=0;for(unsigned i=0;i<6;i++)posted+=m.percpu[i].req_seq;
        if(ipi)assert(posted>0);
        printf("PASS real six-vCPU JIT flush: event=%u ipi=%u posted=%llu flushes=%llu waits=%llu fallback_timeouts=%llu; all guest results exact\n",event,ipi,(unsigned long long)posted,(unsigned long long)m.stats.block_flushes,(unsigned long long)atomic_load(&m.quiesce.waits),(unsigned long long)atomic_load(&m.quiesce.timeouts));
        hv_machine_free(&m);
    }
}
