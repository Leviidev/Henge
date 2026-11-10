"""Exact CPU0 cleanup must release a paused secondary without hv_vm_stop."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'host/vm.c').read_text();start=s.index('static void *cpu0_thread(');end=s.index('\n}\n',start)+3;method=s[start:end]
program='''#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "lifecycle_gate.h"
HvLifecycleGate hv_app_lifecycle=HV_LIFECYCLE_INITIALIZER,hv_cpu_lifecycle=HV_LIFECYCLE_INITIALIZER;
pthread_mutex_t hv_lifecycle_state_mu=PTHREAD_MUTEX_INITIALIZER;
static _Atomic int parked,returned,exited,kicker_stopped;static int m,ncpus=2,secondary_started[2],kicker_started;
static pthread_t secondary_threads[2],kicker;static struct{void*root_blk,*aux_blk;}board;
#define HV_HALT_HOST 3
static void hv_vm_cpu_qos(void){}
static int hv_vm_run_cpu0(void){while(!atomic_load(&parked))usleep(1000);return 71;}
static void hv_machine_halt(void*p,int reason){(void)p;(void)reason;/* no lifecycle cancellation */}
static void hv_virtio_blk_stop(void*p){(void)p;}
static void hv_audio_detach(void){}
static void hv_vm_flush_disks(void){}
static void finished(int reason){if(reason==71)atomic_store(&exited,1);}
static void(*exit_cb)(int)=finished;
METHOD
static void*secondary(void*p){(void)p;atomic_store(&parked,1);if(!hv_lifecycle_wait(&hv_cpu_lifecycle))atomic_store(&returned,1);return NULL;}
int main(){hv_lifecycle_set_active(&hv_app_lifecycle,0);hv_lifecycle_set_active(&hv_cpu_lifecycle,0);secondary_started[1]=1;
 pthread_create(&secondary_threads[1],NULL,secondary,NULL);pthread_t primary;pthread_create(&primary,NULL,cpu0_thread,NULL);
 for(int n=0;n<500&&!atomic_load(&exited);n++)usleep(1000);
 int stalled=!atomic_load(&exited);if(stalled)hv_lifecycle_cancel(&hv_cpu_lifecycle); /* bounded old-code cleanup */
 pthread_join(primary,NULL);
 if(!atomic_load(&returned)||!atomic_load(&exited)||!atomic_load(&hv_app_lifecycle.cancelled)||!atomic_load(&hv_cpu_lifecycle.cancelled))return 2;
 printf("natural exit with paused secondary: cleanup_needed=%d\\n",stalled);return stalled?3:0;
}
'''
assert 'hv_vm_stop(' not in method
with tempfile.TemporaryDirectory()as t:
 p=Path(t)
 for label,body,expected in [('fixed',method,0),('old',method.replace('    hv_lifecycle_cancel(&hv_cpu_lifecycle);\n',''),3)]:
  (p/(label+'.c')).write_text(program.replace('METHOD',body));exe=p/label
  subprocess.run(['xcrun','--sdk','macosx','clang','-std=gnu11','-Wall','-Wextra','-Werror','-I'+str(root/'host'),str(p/(label+'.c')),'-o',str(exe)],check=True)
  q=subprocess.run([str(exe)],capture_output=True,text=True,timeout=5);print(label+': '+q.stdout.strip());assert q.returncode==expected,(q.returncode,q.stderr)
print('Fixed natural-exit path completes; old path needs explicit harness cancellation; no hv_vm_stop/GPU/guest')
