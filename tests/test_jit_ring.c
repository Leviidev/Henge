#include "machine.h"
#include "dispatch.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
/* Real four-vCPU dispatch, translations, cross-page chains and global eviction.
   Each basic block is on a different page so repair cannot pass on same-page
   chains alone. No ROM, timer sleeps or device fixture is involved. */
static HvMachine machine;
static HvCpu cpus[4];
static pthread_mutex_t ready_mu=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready_cv=PTHREAD_COND_INITIALIZER;
static unsigned ready_count;
static void *run_cpu(void *opaque) {
    HvCpu *cpu=opaque;hv_self=cpu;
    pthread_mutex_lock(&ready_mu);
    if(++ready_count==4)pthread_cond_broadcast(&ready_cv);
    while(ready_count<4)pthread_cond_wait(&ready_cv,&ready_mu);
    pthread_mutex_unlock(&ready_mu);
    int result=hv_run(cpu);
    return (void *)(uintptr_t)result;
}
int main(void) {
    alarm(60);
    assert(!hv_machine_init(&machine,64<<10));
    machine.chain_stub_reference=-1; /* force the large-cache inline format through tiny-cache evictions */
    /* 4096 unique blocks exceed 64 KiB even with ideal publication dedup.
       The old 512-block workload could fit when poison-mode timing removed
       concurrent chunk wastage; allocator contention is not eviction proof. */
    enum {blocks=4096,loops=4,page=16384};
    void *memory;assert(!posix_memalign(&memory,page,(blocks+1)*page));memset(memory,0,(blocks+1)*page);
    uint64_t base=(uint64_t)(uintptr_t)memory;
    assert(!hv_machine_add_ram(&machine,base,(blocks+1)*page,memory,0));
    for(int i=0;i<blocks;i++) {uint32_t *code=(uint32_t *)((char *)memory+i*page);code[0]=0x91000400;code[1]=0x14000fff;}
    uint32_t *tail=(uint32_t *)((char *)memory+blocks*page);
    tail[0]=0xf1000421; // subs x1,x1,#1
    tail[1]=0x54000040; // b.eq stop (conditional range is only 1MiB)
    int32_t back=-(blocks*(page/4)+2);
    tail[2]=0x14000000|((uint32_t)back&0x3ffffff); // b first block
    machine.stop_pc=base+blocks*page+12;
    hv_knob[HV_K_JITSEGS]=getenv("HV_TEST_JIT_SEGMENTS")?atoi(getenv("HV_TEST_JIT_SEGMENTS")):2;hv_flush_blocks(&machine);
    uint64_t full=machine.stats.block_flushes;
    for(int round=0;round<2;round++){
        ready_count=0;pthread_t threads[4];
        for(unsigned i=0;i<4;i++){
            hv_cpu_reset_index(&cpus[i],&machine,i);cpus[i].pc=base;cpus[i].x[1]=loops;
            assert(!pthread_create(&threads[i],NULL,run_cpu,&cpus[i]));
        }
        for(int i=0;i<4;i++){
            void *result;assert(!pthread_join(threads[i],&result));
            assert((uintptr_t)result==HV_EXIT_HALT);
            assert(cpus[i].x[0]==(uint64_t)blocks*loops && cpus[i].x[1]==0);
        }
    }
    fprintf(stderr,"ring pressure: evictions=%llu full=%llu initial=%llu translations=%llu capacity_requests=%llu too_big=%u segments=%u\n",
        (unsigned long long)machine.stats.evictions,(unsigned long long)machine.stats.block_flushes,
        (unsigned long long)full,(unsigned long long)machine.stats.translations,
        (unsigned long long)machine.stats.flush_capacity,machine.jit.too_big,machine.jit.nseg);
    assert(machine.stats.evictions>10 && machine.stats.block_flushes==full);
    printf("JIT ring: four vCPUs, %llu evictions, %llu exits repaired, no capacity full reset; cross-page counters correct\n",
        (unsigned long long)machine.stats.evictions,(unsigned long long)machine.stats.evict_unchained);
    hv_machine_free(&machine);free(memory);pthread_cond_destroy(&ready_cv);pthread_mutex_destroy(&ready_mu);
}
