/* Production virtio queue, block workers and file I/O. Only RAM/PCI/CPU-wake
   boundaries are supplied here so the same concurrency test runs on Linux. */
#define _DEFAULT_SOURCE 1
#include "machine.h"
#include "virtio_blk.h"
#include <assert.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

static unsigned char ram[1<<20];
static atomic_uint wakes;
static int overflow_sector;
static int scattered, bad_scatter;
int hv_knob[HV_K_COUNT];
void *hv_phys_ptr(HvMachine *m,uint64_t a,uint64_t n) {
    (void)m;return a<=sizeof ram && n<=sizeof ram-a ? ram+a : NULL;
}
void hv_dma_written(HvMachine *m,uint64_t a,uint64_t n){(void)m;(void)a;(void)n;}
void hv_machine_wake(HvMachine *m){(void)m;atomic_fetch_add(&wakes,1);}
void hv_pci_init(HvPciDev *d,uint16_t a,uint16_t b,uint32_t c,uint16_t e,uint16_t f){
    (void)a;(void)b;(void)c;(void)e;(void)f;memset(d,0,sizeof *d);
}
void hv_pci_add_bar(HvPciDev *d,int b,uint64_t n,int w){(void)d;(void)b;(void)n;(void)w;}
int hv_pcie_attach(HvPcie *b,HvPciDev *d){(void)b;(void)d;return 0;}
void hv_pci_set_intx(HvPciDev *d,int l){d->intx=l;}
static void desc(unsigned i,uint64_t a,uint32_t n,uint16_t flags,uint16_t next){
    unsigned char *d=ram+16*i;memcpy(d,&a,8);memcpy(d+8,&n,4);memcpy(d+12,&flags,2);memcpy(d+14,&next,2);
}
static uint16_t used(void){uint16_t n;memcpy(&n,ram+0x11002,2);return n;}
static void submit(HvVirtioBlk *b,unsigned n,unsigned type){
    assert(b->published==b->submitted);
    uint16_t *avail=(uint16_t *)(ram+0x10000);
    for(unsigned i=0;i<n;i++){
        unsigned h=3*i;uint64_t hdr=0x20000+32*i,data=0x30000+512*i,status=0x50000+i;
        uint32_t words[4]={type,0,overflow_sector?0:i,overflow_sector?0x80000000u:0};memcpy(ram+hdr,words,sizeof words);ram[status]=0xff;
        if(type==1)memset(ram+data,(unsigned char)(i+1),512);
        desc(h,hdr,16,1,h+1);
        if(scattered) {
            assert(n==1);
            if(type==1){memset(ram+data,0x6a,256);memset(ram+data+8192,0x9b,256);}
            desc(h+1,data,256,1|(type==0?2:0),h+2);
            desc(h+2,bad_scatter?sizeof ram+1:data+8192,256,1|(type==0?2:0),h+3);
            desc(h+3,status,1,2,0);
        } else {
            desc(h+1,data,type==4||type==0x10000?0:512,1|(type==0?2:0),h+2);
            desc(h+2,status,1,2,0);
        }
        avail[2+avail[1]%256]=(uint16_t)h;avail[1]++;
    }
    b->vio.notify(&b->vio,0);
}
static void wait_done(HvVirtioBlk *b){
    struct timespec start,now;clock_gettime(CLOCK_MONOTONIC,&start);
    while(__atomic_load_n(&b->completed,__ATOMIC_ACQUIRE)!=b->submitted){
        clock_gettime(CLOCK_MONOTONIC,&now);assert(now.tv_sec-start.tv_sec<10);usleep(100);
    }
    /* completed is published before the worker calls the wake boundary. Join
       makes the deterministic burst's wake count exact without timing sleeps. */
    hv_virtio_blk_stop(b);
}
int main(void){
    unsetenv("HV_BLK_STATS"); /* explicitly verify diagnostics-off ownership */
    char path[]="/tmp/henge-block-test-XXXXXX";int fd=mkstemp(path);assert(fd>=0);unlink(path);assert(!ftruncate(fd,1<<20));
    HvDisk disk={.fd=fd,.wfd=-1,.size=1<<20};static HvMachine m;
    HvVirtioBlk *b=hv_virtio_blk_create(&m,NULL,&disk,0);assert(b);
    b->vio.q[0]=(HvVirtq){.size=256,.enabled=1,.desc=0,.avail=0x10000,.used=0x11000};
    hv_virtio_blk_capture_timing(b,1);unsigned epoch=b->capture_epoch;assert(epoch&1);
    hv_virtio_blk_capture_timing(b,1);assert(b->capture_epoch==epoch);
    hv_virtio_blk_capture_timing(b,0);assert(b->capture_epoch==epoch+1);
    uint64_t measured[6];assert(!hv_virtio_blk_read_timing(b,measured)&&measured[0]==0);
    submit(b,64,1);wait_done(b);
    assert(atomic_load(&wakes)==1 && b->completion_pending);
    hv_virtio_blk_poll(b);assert(used()==64 && !b->completion_pending);
    for(unsigned i=0;i<64;i++){unsigned char data[512];assert(!hv_disk_read(&disk,512*i,data,512));assert(data[0]==i+1 && ram[0x50000+i]==0);}
    for(int i=0;i<1000;i++)hv_virtio_blk_poll(b);
    assert(used()==64 && atomic_load(&wakes)==1);
    assert(!hv_virtio_blk_start(b));submit(b,64,0);wait_done(b);hv_virtio_blk_poll(b);
    assert(used()==128 && atomic_load(&wakes)==2);
    for(unsigned i=0;i<64;i++)assert(ram[0x30000+512*i]==i+1);
    /* Race real completions against active polling, repeatedly reuse ring slots
       across wrap and stop/start. A missing publication loses a used entry. */
    for(int batch=0;batch<64;batch++){
        assert(!hv_virtio_blk_start(b));unsigned before=used();submit(b,64,0);
        struct timespec start,now;clock_gettime(CLOCK_MONOTONIC,&start);
        while(used()!=before+64){
            hv_virtio_blk_poll(b);clock_gettime(CLOCK_MONOTONIC,&now);assert(now.tv_sec-start.tv_sec<10);
        }
        wait_done(b);hv_virtio_blk_poll(b);assert(b->published==b->submitted);
    }
    assert(!b->io_shape[0] && !b->io_shape[1] && !b->io_shape[2]);
    hv_virtio_blk_capture_timing(b,1);
    assert(!hv_virtio_blk_start(b));submit(b,1,4);hv_virtio_blk_drain(b);assert(ram[0x50000]==0);
    assert(hv_virtio_blk_read_timing(b,measured) && measured[0]>=1 && measured[5]>=1);
    submit(b,1,0x10000);hv_virtio_blk_drain(b);assert(ram[0x50000]==0);
    submit(b,1,0);hv_virtio_blk_drain(b);assert(ram[0x50000]==0);
    /* An overflowing sector must not wrap to sector zero, corrupt the disk,
       or return success to the guest. Run both directions on the real queue. */
    unsigned char first[512],after[512];assert(!hv_disk_read(&disk,0,first,sizeof first));overflow_sector=1;
    submit(b,1,1);hv_virtio_blk_drain(b);assert(ram[0x50000]==1);
    submit(b,1,0);hv_virtio_blk_drain(b);assert(ram[0x50000]==1 && b->errors==2);
    assert(!hv_disk_read(&disk,0,after,sizeof after) && !memcmp(first,after,sizeof first));
    overflow_sector=0;scattered=1;
    submit(b,1,1);hv_virtio_blk_drain(b);assert(ram[0x50000]==0);
    assert(!hv_disk_read(&disk,0,first,sizeof first));
    for(unsigned i=0;i<512;i++)assert(first[i]==(i<256?0x6a:0x9b));
    memset(ram+0x30000,0xcc,256);memset(ram+0x32000,0xcc,256);
    submit(b,1,0);hv_virtio_blk_drain(b);assert(ram[0x50000]==0);
    for(unsigned i=0;i<256;i++)assert(ram[0x30000+i]==0x6a && ram[0x32000+i]==0x9b);
    /* A bad later vector must not partially write the disk's earlier one. */
    bad_scatter=1;submit(b,1,1);hv_virtio_blk_drain(b);assert(ram[0x50000]==1 && b->errors==3);
    assert(!hv_disk_read(&disk,0,after,sizeof after) && !memcmp(first,after,sizeof first));
    assert(b->io_shape[0]==1 && b->io_shape[1]==2 && b->io_shape[2]==4);
    hv_virtio_blk_stop(b);assert(hv_virtio_blk_idle(b));hv_virtio_blk_destroy(b);close(fd);
    puts("block completion: 64 ready requests / 1 wake; 4096 raced completions, ring wrap, read/write, flush, barrier, restart and sector-overflow rejection passed");
    puts("PASS real virtqueue -> scattered DMA -> real preadv/pwritev; status/payload integrity and validate-before-file-write on invalid later vector");
}
