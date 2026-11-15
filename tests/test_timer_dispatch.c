#include "machine.h"
#include "sysreg.h"
#include <assert.h>
#include <stdio.h>
static unsigned timer_calls, device_polls;
static uint64_t only_timer(HvMachine *m,HvCpu *c) { assert(c->m==m);timer_calls++;return 12345; }
static uint64_t poll_devices(HvMachine *m,HvCpu *c) { assert(c->m==m);device_polls++;return 54321; }
int main(void) {
 static HvMachine m;static HvCpu cpu;
 assert(hv_machine_init(&m,1<<20)==0);hv_cpu_reset(&cpu,&m);cpu.el=1;
 m.tick=poll_devices;m.timer_changed=only_timer;
 const uint32_t regs[]={0xdf10,0xdf11,0xdf12,0xdf18,0xdf19,0xdf1a};
 // R(3,3,14,2/3,0/1/2): real TVAL, CTL, CVAL writes
 for(unsigned i=0;i<sizeof regs/sizeof regs[0];i++) {
  cpu.x[0]=1; assert(hv_sysreg_msr(&cpu,0xd5100000u|(regs[i]<<5),0)==0);
 }
 assert(timer_calls==6 && device_polls==0 && cpu.timer_due==12345);
 m.timer_changed=NULL;
 assert(hv_sysreg_msr(&cpu,0xd5100000u|(regs[0]<<5),0)==0);
 assert(timer_calls==6 && device_polls==1 && cpu.timer_due==54321);
 hv_machine_free(&m);
 puts("timer register dispatch: six immediate updates, zero incidental device polls, generic fallback passed");
}
