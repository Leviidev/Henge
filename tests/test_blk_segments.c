/* Execute production descriptor coalescing with observable I/O boundaries. */
#define _DEFAULT_SOURCE 1
#include "../devices/virtio_blk.c"
#include <assert.h>
static unsigned char ram[65536], disk[65536];
static unsigned calls, invalidations, last_count;
static int fail_partial;
static uint64_t region_end = sizeof ram;
void *hv_phys_ptr(HvMachine *m,uint64_t a,uint64_t n) {
    (void)m;
    if(a > sizeof ram || n > sizeof ram-a) return NULL;
    if(a < region_end && n > region_end-a) return NULL;
    return ram+a;
}
int hv_disk_read(HvDisk *d,uint64_t off,void *p,uint64_t n) {
    (void)d;calls++;if(off>sizeof disk || n>sizeof disk-off)return -1;
    memcpy(p,disk+off,n);return 0;
}
int hv_disk_write(HvDisk *d,uint64_t off,const void *p,uint64_t n) {
    (void)d;calls++;if(off>sizeof disk || n>sizeof disk-off)return -1;
    memcpy(disk+off,p,n);return 0;
}
int hv_disk_readv(HvDisk *d,uint64_t off,const struct iovec *iov,int count) {
    (void)d;calls++;last_count=count;
    for(int i=0;i<count;i++) {
        if(off>sizeof disk || iov[i].iov_len>sizeof disk-off)return -1;
        memcpy(iov[i].iov_base,disk+off,iov[i].iov_len);off+=iov[i].iov_len;
        if(fail_partial)return -1;
    }return 0;
}
int hv_disk_writev(HvDisk *d,uint64_t off,const struct iovec *iov,int count) {
    (void)d;calls++;last_count=count;
    for(int i=0;i<count;i++) {
        if(off>sizeof disk || iov[i].iov_len>sizeof disk-off)return -1;
        memcpy(disk+off,iov[i].iov_base,iov[i].iov_len);off+=iov[i].iov_len;
    }return 0;
}
void hv_dma_written(HvMachine *m,uint64_t a,uint64_t n){(void)m;(void)a;(void)n;invalidations++;}
int main(void) {
    HvDisk d={.size=sizeof disk};HvVirtioBlk b={.disk=&d,.log_stats=1};HvVirtqElem e={.nseg=5};
    for(unsigned i=0;i<sizeof disk;i++)disk[i]=(unsigned char)(i*17);
    for(int i=0;i<4;i++)e.seg[i]=(HvVirtqSeg){.addr=4096+i*4096,.len=4096,.write=1};
    e.seg[4]=(HvVirtqSeg){.addr=20480,.len=1,.write=1};ram[20480]=0xa7;
    assert(!seg_io(&b,&e,1,0,0,16384));assert(calls==1 && invalidations==1);
    assert(!memcmp(ram+4096,disk,16384) && ram[20480]==0xa7);
    /* Header skipping, unaligned first/last pages, no write staging copy. */
    for(int i=0;i<5;i++)e.seg[i].write=0;
    calls=0;assert(!seg_io(&b,&e,0,16,32,16352));assert(calls==1);
    assert(!memcmp(disk+32,ram+4112,16352));
    /* Noncontiguous pages and RAM mapping boundaries must remain separate. */
    calls=0;invalidations=0;region_end=8192;
    assert(!seg_io(&b,&e,0,0,0,16384));assert(calls==1 && last_count==2);
    region_end=sizeof ram;calls=0;e.seg[1].addr=24576;
    assert(!seg_io(&b,&e,0,0,0,16384));assert(calls==1 && last_count==3);
    assert(!memcmp(disk,ram+4096,4096) && !memcmp(disk+4096,ram+24576,4096) && !memcmp(disk+8192,ram+12288,8192));
    /* Wrong direction, short chains, invalid addresses and disk errors. */
    e.seg[1].write=1;calls=0;assert(!seg_io(&b,&e,0,0,0,12288));assert(calls==1 && last_count==2);
    calls=0;assert(seg_io(&b,&e,0,0,0,20000)==-1 && !calls);
    e.seg[0].addr=UINT64_MAX-7;assert(seg_io(&b,&e,0,16,0,1)==-1);
    e.seg[0].addr=65530;assert(seg_io(&b,&e,0,0,0,4096)==-1);
    e.seg[0].addr=4096;invalidations=0;
    assert(seg_io(&b,&e,1,0,sizeof disk,4096)==-1 && !invalidations);
    /* Partial failed DMA still invalidates every potentially written span. */
    e.seg[0].write=1;fail_partial=1;calls=0;
    assert(seg_io(&b,&e,1,0,0,8192)==-1 && calls==1 && invalidations==2);
    assert(b.io_shape[0]==2 && b.io_shape[1]==4 && b.io_shape[2]==9);
    e.nseg=HV_VIRTQ_MAX_SEGS+1;assert(seg_io(&b,&e,1,0,0,1)==-1);
    puts("block segments: adjacent and scattered pages / 1 I/O; distinct mappings, status/header/direction, all-before-I/O validation and partial-DMA invalidation passed");
}
