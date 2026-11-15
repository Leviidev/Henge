#include "machine.h"
#include <stdint.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include <sys/resource.h>
static uint64_t arbitrations;
void hv_cpu_wake(HvCpu *c){(void)c;}
int hv_machine_add_mmio(HvMachine *m,uint64_t pa,uint64_t size,void *o,
 uint64_t (*read)(void*,uint64_t,unsigned),void (*write)(void*,uint64_t,uint64_t,unsigned),const char *name){
 (void)m;(void)pa;(void)size;(void)o;(void)read;(void)write;(void)name;return 0;
}
#include GIC_SOURCE
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
int main(void){
 static HvMachine m;static HvGic g;g.m=&m;m.ncpus=4;g.ctlr=3;
 pthread_mutexattr_t attr;pthread_mutexattr_init(&attr);pthread_mutexattr_settype(&attr,PTHREAD_MUTEX_RECURSIVE);pthread_mutex_init(&g.mu,&attr);
 for(int c=0;c<4;c++){g.cpu[c].pmr=255;g.cpu[c].igrpen1=1;g.cpu[c].enabled[27]=g.cpu[c].enabled[30]=1;g.cpu[c].group[27]=g.cpu[c].group[30]=1;g.cpu[c].priority[27]=64;g.cpu[c].priority[30]=96;}
 double start=now();
 for(unsigned i=0;i<200000;i++){
 #ifdef PAIRED
  hv_gicv3_set_timer_lines(&g,0,i&1,(i>>1)&1);
 #else
  hv_gicv3_set_ppi(&g,0,27,i&1);hv_gicv3_set_ppi(&g,0,30,(i>>1)&1);
 #endif
 }
 double elapsed=now()-start;struct rusage use;getrusage(RUSAGE_SELF,&use);
 printf("{\"iterations\":200000,\"cpu_count\":4,\"arbitrations\":%llu,\"elapsed_ms\":%.6f,\"process_cpu_ms\":%.6f,\"irq_final\":%u}\n",(unsigned long long)arbitrations,elapsed*1000,(use.ru_utime.tv_sec+use.ru_stime.tv_sec)*1000+(use.ru_utime.tv_usec+use.ru_stime.tv_usec)/1000.0,m.percpu[0].irq_line);
}
