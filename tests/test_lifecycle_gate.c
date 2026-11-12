#include "lifecycle_gate.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>
static HvLifecycleGate gpu=HV_LIFECYCLE_INITIALIZER,cpu=HV_LIFECYCLE_INITIALIZER;
static pthread_mutex_t mu=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv=PTHREAD_COND_INITIALIZER;
static int encoded,allow_commit;
static _Atomic int stamps,cpu_ran,stop_flag,wait_started;
static int order[64];
static void *replay(void *unused){
 (void)unused;
 for(int i=1;i<=64;i++){
  if(!hv_lifecycle_wait(&gpu))return NULL;
  if(i==7){pthread_mutex_lock(&mu);encoded=7;pthread_cond_broadcast(&cv);while(!allow_commit)pthread_cond_wait(&cv,&mu);pthread_mutex_unlock(&mu);}
  if(!hv_lifecycle_wait(&gpu))return NULL;
  order[atomic_load(&stamps)]=i;atomic_fetch_add(&stamps,1);
 }
 return NULL;
}
static void *guest(void *unused){(void)unused;if(hv_lifecycle_wait(&cpu))atomic_store(&cpu_ran,1);return NULL;}
static void *cancelled_wait(void *unused){(void)unused;atomic_store(&wait_started,1);assert(!hv_lifecycle_wait_stoppable(&gpu,&stop_flag));return NULL;}
int main(void){
 pthread_t worker,vCPU;
 hv_lifecycle_set_active(&cpu,0);
 assert(!pthread_create(&vCPU,NULL,guest,NULL));
 assert(!pthread_create(&worker,NULL,replay,NULL));
 pthread_mutex_lock(&mu);while(encoded!=7)pthread_cond_wait(&cv,&mu);
 hv_lifecycle_set_active(&gpu,0);allow_commit=1;pthread_cond_broadcast(&cv);pthread_mutex_unlock(&mu);
 usleep(30000);
 assert(atomic_load(&stamps)==6 && !atomic_load(&cpu_ran));
 /* Publisher cannot deadlock on the gate's waiter mutex. */
 pthread_mutex_lock(&gpu.mu);hv_lifecycle_set_active(&gpu,1);pthread_mutex_unlock(&gpu.mu);
 pthread_join(worker,NULL);
 assert(atomic_load(&stamps)==64 && !atomic_load(&cpu_ran));
 for(int i=0;i<64;i++)assert(order[i]==i+1);
 /* Fake completed GPU-drain notification releases the CPU only afterward. */
 hv_lifecycle_set_active(&cpu,1);pthread_join(vCPU,NULL);assert(atomic_load(&cpu_ran));
 hv_lifecycle_set_active(&gpu,0);atomic_store(&wait_started,0);
 assert(!pthread_create(&worker,NULL,cancelled_wait,NULL));
 while(!atomic_load(&wait_started))usleep(1000);
 atomic_store(&stop_flag,1);pthread_cond_broadcast(&gpu.cv);pthread_join(worker,NULL);
 atomic_store(&stop_flag,0);atomic_store(&wait_started,0);
 assert(!pthread_create(&worker,NULL,cancelled_wait,NULL));
 while(!atomic_load(&wait_started))usleep(1000);
 hv_lifecycle_cancel(&gpu);pthread_join(worker,NULL);
 hv_lifecycle_restart(&gpu);assert(!hv_lifecycle_allowed(&gpu));
 hv_lifecycle_set_active(&gpu,1);assert(hv_lifecycle_wait(&gpu));
 puts("PASS: 64 retained commands/stamps ordered, paused mid-command, GPU-first CPU release, nonlocking UI publication, replay-stop and VM-cancel wakeups, restart stays inactive");
 return 0;
}
