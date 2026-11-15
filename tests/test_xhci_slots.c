/* Exercise the production command parser and guest event-ring completions. */
#include "../devices/xhci.c"
#include <assert.h>
static HvMachine machine;
static HvXhci controller;
static uint8_t memory[16384] __attribute__((aligned(16384)));
static void gamepad_checks(void) {
    HvXhci *x=&controller;
    memset(memory,0,sizeof memory);reset(x);
    assert(!(x->portsc[2]&PORT_CCS));
    int16_t axes[4]={1000,-2000,3000,-4000};
    hv_xhci_gamepad(x,1,1,8,axes,0,255);hv_xhci_poll(x);
    assert(x->gp_online && (x->portsc[2]&PORT_CCS));
    x->slots[1].dev=2;
    uint8_t reply[256],setup[8]={0x81,6,0,0x22,0,0,255,0};
    int n=control(x,1,setup,reply,sizeof reply);
    assert(n==(int)sizeof hv_gamepad_descriptor && !memcmp(reply,hv_gamepad_descriptor,n));
    setup[0]=0xa1;setup[1]=1;setup[2]=0;setup[3]=1;
    assert(control(x,1,setup,reply,sizeof reply)==HV_GAMEPAD_BYTES);
    assert(reply[0]==1 && reply[2]==8 && reply[12]==255);
    // Deliver both press and release through actual guest IN transfer TRBs.
    hv_xhci_gamepad(x,1,0,8,axes,0,0);
    assert(x->gp_tail-x->gp_head==2);
    struct HvXhciIntr *it=&x->intr[0];
    it->erstsz=1;it->seg_base=0x101000;it->seg_size=8;it->index=0;it->pcs=1;
    uint32_t *trb=(void *)memory;
    for(unsigned i=0;i<2;i++){trb[4*i]=0x102000+32*i;trb[4*i+2]=16;trb[4*i+3]=TRB_NORMAL<<10|1;}
    x->slots[1].ep[3]=(HvXhciRing){.dequeue=0x100000,.ccs=1};
    x->slots[1].ep_running[3]=1;
    run_ep_in(x,1);
    assert(x->gp_delivered==2 && x->gp_head==x->gp_tail);
    assert(memory[8192]==1 && memory[8224]==0);
    uint32_t *event=(void *)(memory+4096);
    assert(event[2]>>24==CC_SHORT_PACKET && (event[2]&0xffffff)==3);
    // Axes coalesce; button/hat/trigger edges remain ordered. Overflow ends
    // at the authoritative neutral state, so releases cannot remain stuck.
    hv_xhci_gamepad(x,1,0,8,axes,0,0);axes[0]++;
    hv_xhci_gamepad(x,1,0,8,axes,0,0);axes[0]++;
    hv_xhci_gamepad(x,1,0,8,axes,0,0);
    assert(x->gp_tail-x->gp_head==1 && x->gp_coalesced);
    for(unsigned i=0;i<100;i++)hv_xhci_gamepad(x,1,(i&1)?1:2,8,axes,0,0);
    assert(x->gp_overflow && x->gp_tail-x->gp_head==64);
    hv_xhci_release_input(x);
    assert(x->gp_tail-x->gp_head==1 && !x->gp_state[0] && x->gp_state[2]==8 && !x->gp_desired);
    hv_xhci_gamepad(x,0,0,8,axes,0,0);hv_xhci_poll(x);
    assert(!x->gp_online && !(x->portsc[2]&PORT_CCS));
    // A remote key-up must not release the same physical key, and rollover
    // must recover to the real held set when an owner releases its keys.
    hv_xhci_key_source(x,26,1,0);hv_xhci_key_source(x,26,1,1);
    hv_xhci_release_source(x,1);assert(x->state[2]==26);
    hv_xhci_key_source(x,26,0,0);assert(!x->state[2]);
    hv_xhci_key_source(x,0xe4,1,0);hv_xhci_key_source(x,0xe4,1,4);
    hv_xhci_release_source(x,4);assert(x->state[0]&(1u<<4));
    hv_xhci_key_source(x,0xe4,0,0);assert(!(x->state[0]&(1u<<4)));
    hv_xhci_key_source(x,26,1,4);hv_xhci_key_source(x,26,1,1);
    hv_xhci_release_source(x,1);assert(x->state[2]==26);
    hv_xhci_release_source(x,4);assert(!x->state[2]);
    for(unsigned k=4;k<11;k++)hv_xhci_key_source(x,k,1,2);
    assert(x->state[2]==1 && x->state[7]==1);
    hv_xhci_release_source(x,2);assert(!x->state[2]);
    hv_xhci_key_source(x,26,1,0);hv_xhci_key_source(x,26,1,2);hv_xhci_key_source(x,26,1,3);
    hv_xhci_release_source(x,3);assert(x->state[2]==26);
    hv_xhci_release_source(x,2);assert(x->state[2]==26);
    hv_xhci_key_source(x,26,0,0);assert(!x->state[2]);
    puts("PASS xHCI gamepad: hotplug, descriptors, real IN transfers, coalescing, overflow neutral and input ownership");
}
static void compatible_gamepad_checks(void) {
    HvXhci *x=&controller;
    x->gp_profile=1;x->gp_desired=0;memset(memory,0,sizeof memory);reset(x);x->slots[1].dev=2;
    uint8_t reply[1024],setup[8]={0x80,6,0,1,0,0,18,0};
    assert(control(x,1,setup,reply,sizeof reply)==18 && reply[8]==0x4c && reply[10]==0xc4);
    setup[3]=2;assert(control(x,1,setup,reply,sizeof reply)==41 && reply[13]==2);
    setup[0]=0x81;setup[3]=0x22;
    assert(control(x,1,setup,reply,sizeof reply)==507 && !memcmp(reply,hv_ds4_descriptor,507));
    // Full descriptor through the real EP0 ring, including its >256-byte tail.
    struct HvXhciIntr *it=&x->intr[0];it->erstsz=1;it->seg_base=0x101000;it->seg_size=16;it->index=0;it->pcs=1;
    uint32_t *trb=(void *)memory;
    trb[0]=0x22000681;trb[1]=507u<<16;trb[2]=8;trb[3]=TRB_SETUP<<10|1;
    trb[4]=0x102000;trb[6]=507;trb[7]=TRB_DATA<<10|1|1u<<16;
    trb[11]=TRB_STATUS<<10|1|1u<<5;
    x->slots[1].ep[1]=(HvXhciRing){.dequeue=0x100000,.ccs=1};run_ep0(x,1);
    assert(!memcmp(memory+8192,hv_ds4_descriptor,507));
    setup[0]=0xa1;setup[1]=1;setup[2]=2;setup[3]=3;
    assert(control(x,1,setup,reply,sizeof reply)==37 && reply[0]==2);
    setup[2]=0x12;assert(control(x,1,setup,reply,sizeof reply)==16);
    setup[2]=0xa3;assert(control(x,1,setup,reply,sizeof reply)==49);
    setup[2]=0xfe;assert(control(x,1,setup,reply,sizeof reply)==-1);
    int16_t axes[4]={-32767,32767,0,0};hv_xhci_gamepad(x,1,1,8,axes,0,255);hv_xhci_poll(x);
    memset(memory,0,64);trb[0]=0x102000;trb[2]=64;trb[3]=TRB_NORMAL<<10|1;
    x->slots[1].ep[3]=(HvXhciRing){.dequeue=0x100000,.ccs=1};x->slots[1].ep_running[3]=1;
    run_ep_in(x,1);
    assert(memory[8192]==1 && memory[8193]==0 && memory[8194]==255 && (memory[8197]&0x20) && memory[8201]==255);
    // Valid feedback completes without taking the IN ring; malformed feedback stalls.
    memset(memory,0,64);trb[0]=0x102400;trb[2]=32;trb[3]=TRB_NORMAL<<10|1;memory[9216]=5;
    x->slots[1].ep[4]=(HvXhciRing){.dequeue=0x100000,.ccs=1};x->slots[1].ep_running[4]=1;
    run_ep_out(x,1,4);assert(x->slots[1].ep[4].dequeue==0x100010 && x->slots[1].ep_running[4]);
    trb[4]=0x102400;trb[6]=32;trb[7]=TRB_NORMAL<<10|1;memory[9216]=0xff;
    run_ep_out(x,1,4);assert(!x->slots[1].ep_running[4]);
    hv_xhci_release_input(x);hv_xhci_poll(x);assert(!x->gp_online && x->gp_profile==1);
    puts("PASS PS4-compatible xHCI: full descriptor EP0, features, real 64-byte IN, separate validated OUT, disconnect and persistent identity");
    x->gp_profile=0;
}
int main(void) {
    assert(!hv_machine_init(&machine,1<<20));
    assert(!hv_machine_add_ram(&machine,0x100000,sizeof memory,memory,0));
    controller.m=&machine;
    assert(!pthread_mutex_init(&controller.mu,NULL));
    struct HvXhciIntr *it=&controller.intr[0];
    unsigned count=0;
    for(unsigned type=9;type<=23;type++)for(unsigned slot=0;slot<256;slot++) {
        if(slot>=1 && slot<=HV_XHCI_SLOTS)continue;
        memset(memory,0,sizeof memory);memset(controller.slot_used,0,sizeof controller.slot_used);
        uint32_t *cmd=(void *)memory;
        cmd[3]=type<<10|slot<<24|1;
        controller.cmd=(HvXhciRing){.dequeue=0x100000,.ccs=1};
        it->erstsz=1;it->seg_base=0x101000;it->seg_size=8;it->index=0;it->pcs=1;
        run_commands(&controller);
        uint32_t *event=(void *)(memory+4096);
        unsigned want=(type==TRB_ENABLE_SLOT || type==TRB_NOOP_CMD)?CC_SUCCESS:CC_SLOT_NOT_ENABLED;
        assert(event[2]>>24==want);
        assert(((event[3]>>10)&63)==TRB_CMD_COMPLETION);
        assert(controller.cmd.dequeue==0x100010);
        count++;
    }
    gamepad_checks();
    puts("PASS xHCI keyboard owners: hardware4, shortcuts0 and remote sources retain independent modifiers");
    compatible_gamepad_checks();
    pthread_mutex_destroy(&controller.mu);
    hv_machine_free(&machine);
    printf("PASS xHCI: %u invalid-slot command/event-ring cases; enable/no-op exceptions preserved\n",count);
}
