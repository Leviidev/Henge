#include "machine.h"
#include <pthread.h>
#include <stdatomic.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
void (*hv_prof_register)(void);void (*hv_prof_unregister)(void);void (*hv_prof_session)(int);
HvMachine *hv_vm_machine(void){return NULL;}
void hv_prof_ios_start(void);
void hv_prof_test_counts(uint64_t*,uint64_t*,unsigned*);
static void *worker(void *unused){
 (void)unused;hv_prof_register();hv_prof_register();
 uint64_t samples,dumps;unsigned ports;hv_prof_test_counts(&samples,&dumps,&ports);assert(ports==1);
 for(int j=0;j<500000;j++)atomic_signal_fence(memory_order_seq_cst);
 usleep(unused?100000:25000);if(unused){hv_prof_unregister();hv_prof_test_counts(&samples,&dumps,&ports);assert(!ports);}
 return NULL;
}
static void *disabled_worker(void *unused){
 (void)unused;hv_prof_register();
 uint64_t samples,dumps;unsigned ports;hv_prof_test_counts(&samples,&dumps,&ports);assert(!ports);
 usleep(30000);hv_prof_unregister();return NULL;
}
int main(void){
 setenv("HV_PROF_IOS","0",1);hv_prof_ios_start();
 assert(!hv_prof_register && !hv_prof_session);
 setenv("HV_PROF_IOS","1",1);setenv("HV_PROF_IOS_HZ","100",1);
 setenv("HV_PROF_IOS_SECS","0",1);setenv("HV_PROF_IOS_DURATION","1",1);
 hv_prof_ios_start();assert(hv_prof_register&&hv_prof_session);hv_prof_session(1);
 for(int i=0;i<24;i++){pthread_t t;assert(!pthread_create(&t,NULL,worker,NULL));pthread_join(t,NULL);}
 uint64_t samples,dumps;unsigned ports;hv_prof_test_counts(&samples,&dumps,&ports);assert(!ports&&samples>0);
 usleep(500000);hv_prof_test_counts(&samples,&dumps,&ports);assert(dumps>=1);
 hv_prof_session(0);usleep(30000);uint64_t stopped=samples;hv_prof_test_counts(&stopped,&dumps,&ports);
 usleep(50000);hv_prof_test_counts(&samples,&dumps,&ports);assert(samples==stopped);
 hv_prof_session(1);pthread_t t;pthread_create(&t,NULL,worker,(void*)1);pthread_join(t,NULL);
 hv_prof_test_counts(&samples,&dumps,&ports);assert(!ports&&samples>stopped);
 hv_prof_session(0);
 setenv("HV_PROF_IOS","0",1);hv_prof_ios_start();hv_prof_session(1);
 hv_prof_test_counts(&stopped,&dumps,&ports);assert(!ports);
 pthread_create(&t,NULL,disabled_worker,NULL);pthread_join(t,NULL);
 hv_prof_test_counts(&samples,&dumps,&ports);assert(samples==stopped && !ports);
 setenv("HV_PROF_IOS","1",1);hv_prof_ios_start();hv_prof_session(1);
 pthread_create(&t,NULL,worker,(void*)1);pthread_join(t,NULL);hv_prof_session(0);
 hv_prof_test_counts(&samples,&dumps,&ports);assert(samples>stopped && !ports);
 puts("iOS profiler lifecycle: off/on/off/on, port reuse across 24 threads, idempotent registration, duration, invalid interval, stopped session sleep and restart passed");
}
