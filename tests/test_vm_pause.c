/* Reuse the authored tiny-ROM fixture helpers, not a real user VM/disk. */
#define main reference_vm_lifecycle_main
#include "test_vm_lifecycle.c"
#undef main
#include "sysreg.h"
static int wait_blocks(uint64_t before) {
    for(int n=0;n<2000;n++){if(henge_vm_blocks()>before)return 1;usleep(1000);}return 0;
}
static int wait_parked(void) {
    for(int n=0;n<2000;n++){
        int all=1;
        for(int i=0;i<hv_vm_ncpus();i++){
            HvCpu *c=hv_vm_cpu(i);
            if(c->pc_state && __atomic_load_n(&c->pc_state->active,__ATOMIC_SEQ_CST))all=0;
        }
        if(all)return 1;
        usleep(1000);
    }
    return 0;
}
int main(void) {
    char dir[]="/tmp/henge-pause-XXXXXX",rom[256],disk[256],aux[256],ram[256],error[256];
    if(!mkdtemp(dir)||hv_jit_region_open(&jit,8<<20))return 1;
    snprintf(rom,sizeof rom,"%s/rom",dir);snprintf(disk,sizeof disk,"%s/disk",dir);
    snprintf(aux,sizeof aux,"%s/aux",dir);snprintf(ram,sizeof ram,"%s/ram",dir);
    setenv("HV_RAM_FILE",ram,1);setenv("HV_RAM_NO_LEDGER","1",1);setenv("HV_BALLOON","0",1);
    uint32_t branch=0x14000000;write_file(rom,&branch,4);write_file(disk,NULL,1<<20);write_file(aux,NULL,1<<20);
    mapping=(HengeDualMapping){.rx_addr=(uint8_t *)jit.base,.rw_addr=(uint8_t *)jit.base+jit.rw_diff,.size=jit.capacity*4};
    henge_vm_set_app_active(1);
    int rc=henge_vm_boot(rom,disk,aux,1,0,64,4,error,sizeof error);
    check("tiny authored guest starts",rc==0);if(rc)return 1;
    uint64_t offset=hv_vm_cpu(0)->cntvoff;
    check("virtual counter begins near zero",offset>0 && hv_counter()-offset<24000000ULL*5);
    for(int i=0;i<4;i++)check("all CPUs share boot counter origin",hv_vm_cpu(i)->cntvoff==offset);
    check("CPU initially progresses",wait_blocks(0));
    for(int i=0;i<3;i++){
        henge_vm_set_app_active(0);
        check("all CPUs park",wait_parked());
        uint64_t paused=henge_vm_blocks();usleep(30000);
        check("paused guest blocks remain stable",henge_vm_blocks()==paused);
        check("pause keeps running VM identity",henge_vm_state()==1 && henge_vm_generation()==1);
        henge_vm_set_app_active(1);
        check("GPU drain callback releases CPUs",wait_blocks(paused));
    }
    henge_vm_set_app_active(0);henge_vm_set_app_active(1);henge_vm_set_app_active(0);
    check("rapid phase reversal leaves CPUs parked",wait_parked());
    uint64_t paused=henge_vm_blocks();usleep(30000);check("stale resume cannot unpark",henge_vm_blocks()==paused);
    henge_vm_stop();
    for(int n=0;n<3000 && henge_vm_state()!=2;n++)usleep(1000);
    check("stop while paused completes",henge_vm_state()==2);
    check("stop outcome retained",henge_vm_exit_outcome()==HENGE_VM_OUTCOME_HOST_STOP);
    check("paused stop frees guest RAM",hv_vm_board()->ram==NULL);
    henge_vm_set_app_active(1);usleep(30000);
    rc=henge_vm_boot(rom,disk,aux,1,0,64,4,error,sizeof error);
    check("new VM after paused stop starts",rc==0);
    if(!rc){check("new boot resets virtual counter origin",hv_vm_cpu(0)->cntvoff>offset);check("new active VM does not inherit closed CPU gate",wait_blocks(0));henge_vm_stop();}
    for(int n=0;n<3000 && henge_vm_state()!=2;n++)usleep(1000);
    check("second VM stops",henge_vm_state()==2);
    hv_vm_destroy();hv_jit_region_close(&jit);
    unlink(rom);unlink(disk);unlink(aux);unlink(ram);rmdir(dir);
    printf("Native VM pause/resume/rapid phase/paused stop: %d failures; no GPU guest commands\n",failures);
    return failures!=0;
}
