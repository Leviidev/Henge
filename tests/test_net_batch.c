/* Real virtio-net and split-ring code; only RAM and the PCI boundary are
   supplied. Count interrupt calls, not just an already-asserted INTx level. */
#include "machine.h"
#include "virtio_net.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint8_t ram[1<<20];
static unsigned interrupts;
int hv_knob[HV_K_COUNT];
void *hv_phys_ptr(HvMachine *m,uint64_t a,uint64_t n){(void)m;return a<=sizeof ram&&n<=sizeof ram-a?ram+a:NULL;}
void hv_pci_init(HvPciDev *d,uint16_t a,uint16_t b,uint32_t c,uint16_t e,uint16_t f){(void)a;(void)b;(void)c;(void)e;(void)f;memset(d,0,sizeof *d);}
void hv_pci_add_bar(HvPciDev *d,int b,uint64_t n,int w){(void)d;(void)b;(void)n;(void)w;}
int hv_pcie_attach(HvPcie *bus,HvPciDev *d){(void)bus;(void)d;return 0;}
void hv_pci_set_intx(HvPciDev *d,int level){d->intx=level;if(level)interrupts++;}
static uint16_t used(void){uint16_t n;memcpy(&n,ram+0x11002,2);return n;}
static void offer(unsigned id,unsigned bytes){
    uint64_t address=0x20000+256*id;uint32_t size=bytes;uint16_t flags=2;
    memcpy(ram+16*id,&address,8);memcpy(ram+16*id+8,&size,4);memcpy(ram+16*id+12,&flags,2);
    uint16_t *avail=(uint16_t *)(ram+0x10000);avail[2+avail[1]%64]=(uint16_t)id;avail[1]++;
}
static void contents(unsigned id,const uint8_t *frame){
    const uint8_t *header=ram+0x20000+256*id;
    for(unsigned i=0;i<12;i++)assert(header[i]==(i==10?1:0));
    assert(!memcmp(header+12,frame,64));
}
int main(void){
    static HvMachine machine;uint8_t mac[6]={0};
    HvVirtioNet *net=hv_virtio_net_create(&machine,NULL,mac);assert(net);
    net->vio.status=4;net->vio.q[0]=(HvVirtq){.size=64,.enabled=1,.desc=0,.avail=0x10000,.used=0x11000};
    uint8_t bytes[32][64];const uint8_t *frames[32];uint32_t lengths[32];
    for(unsigned i=0;i<32;i++){memset(bytes[i],(int)i,64);frames[i]=bytes[i];lengths[i]=64;offer(i,128);}
    for(unsigned i=0;i<32;i++)assert(hv_virtio_net_receive(net,frames[i],lengths[i])==1);
    assert(used()==32&&interrupts==32);
    for(unsigned i=0;i<32;i++){contents(i,frames[i]);offer(i,128);}
    interrupts=0;assert(hv_virtio_net_receive_batch(net,frames,lengths,32)==32);
    assert(used()==64&&interrupts==1);
    for(unsigned i=0;i<32;i++)contents(i,frames[i]);
    offer(0,128);offer(1,8);interrupts=0;
    assert(hv_virtio_net_receive_batch(net,frames,lengths,4)==2);
    assert(used()==66&&interrupts==1&&net->rx_dropped==1);
    assert(hv_virtio_net_receive_batch(net,frames+2,lengths+2,2)==0&&interrupts==1);
    offer(2,128);offer(3,128);
    assert(hv_virtio_net_receive_batch(net,frames+2,lengths+2,2)==2&&interrupts==2);
    contents(2,frames[2]);contents(3,frames[3]);
    assert(hv_virtio_net_receive_batch(net,NULL,NULL,0)==0&&interrupts==2);
    for(unsigned round=0;round<2050;round++) {
        for(unsigned i=0;i<32;i++)offer(i,128);
        uint16_t before=used();interrupts=0;
        assert(hv_virtio_net_receive_batch(net,frames,lengths,32)==32);
        assert(used()==(uint16_t)(before+32)&&interrupts==1);
        for(unsigned i=0;i<32;i++)contents(i,frames[i]);
    }
    free(net);puts("PASS network batching: 32 frames / 1 interrupt vs32 single calls; exact headers/order, partial completion, short buffer/drop, retry, empty queue and 16-bit ring wrap");
}
