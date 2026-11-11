/* Offline integration test: actual virtio queue parser, block worker and file
 * backend. Only physical RAM/PCI/CPU-wake plumbing is stubbed; no guest/image.
 * Worker lifetime is process lifetime, matching the device's current API. */
#include "virtio_blk.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

#define BASE 0x100000ull
#define RAM_BYTES (1u << 20)
#define PREFIX 16384u
#define DISK_BYTES (256u << 10)
#define TOTAL (PREFIX + DISK_BYTES)
#define F_DISCARD (1ull << 13)
#define SECTORS (DISK_BYTES / 512)
static uint8_t memory[RAM_BYTES], expected[TOTAL], actual[TOTAL];
static HvMachine machine;
static int checks;
static void check(int ok, const char *name) {
    checks++;
    if (!ok) { fprintf(stderr,"FAIL: %s\n",name); exit(1); }
}
void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) {
    (void)m;
    return pa >= BASE && pa - BASE <= RAM_BYTES && len <= RAM_BYTES - (pa - BASE) ? memory + pa - BASE : NULL;
}
void hv_dma_written(HvMachine *m, uint64_t pa, uint64_t len) { (void)m;(void)pa;(void)len; }
void hv_machine_wake(HvMachine *m) { (void)m; }
void hv_pci_init(HvPciDev *d, uint16_t v, uint16_t id, uint32_t c, uint16_t sv, uint16_t si) {
    (void)d;(void)v;(void)id;(void)c;(void)sv;(void)si;
}
void hv_pci_add_bar(HvPciDev *d,int bar,uint64_t size,int is64) { (void)d;(void)bar;(void)size;(void)is64; }
int hv_pcie_attach(HvPcie *p,HvPciDev *d) { (void)p;(void)d;return 0; }
void hv_pci_set_intx(HvPciDev *d,int level) { (void)d;(void)level; }
/* host/disk.c is built with these two names redirected, so the wrapper can
 * delay/fail real disk writes deterministically without a production test hook. */
int fixture_disk_write_real(HvDisk *,uint64_t,const void *,uint64_t);
int fixture_disk_flush_real(HvDisk *);
static pthread_mutex_t gate_mu=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cv=PTHREAD_COND_INITIALIZER;
static int delay_next,entered,release_gate,fail_at,write_calls,flush_calls;
int hv_disk_write(HvDisk *d,uint64_t off,const void *buf,uint64_t len) {
    pthread_mutex_lock(&gate_mu);
    int fail=fail_at && ++write_calls==fail_at;
    if(delay_next) {
        delay_next=0;entered=1;pthread_cond_broadcast(&gate_cv);
        while(!release_gate)pthread_cond_wait(&gate_cv,&gate_mu);
    }
    pthread_mutex_unlock(&gate_mu);
    return fail ? -1 : fixture_disk_write_real(d,off,buf,len);
}
int hv_disk_flush(HvDisk *d) { __atomic_add_fetch(&flush_calls,1,__ATOMIC_RELAXED);return fixture_disk_flush_real(d); }
/* Disk flush's regular mode is zero/fsync. */
int hv_knob[HV_K_COUNT];

static uint8_t *ptr(uint64_t pa) { return hv_phys_ptr(&machine,pa,1); }
static void desc(unsigned i,uint64_t pa,uint32_t len,uint16_t flags,uint16_t next) {
    uint8_t *d=memory+i*16;
    memcpy(d,&pa,8);memcpy(d+8,&len,4);memcpy(d+12,&flags,2);memcpy(d+14,&next,2);
}
static uint64_t request(unsigned id,uint32_t type,uint64_t sector,const void *data,uint32_t len) {
    uint64_t p=BASE+0x10000+id*0x2000;
    struct {uint32_t type,reserved;uint64_t sector;} h={type,0,sector};
    memcpy(ptr(p),&h,sizeof h);
    if(len&&data)memcpy(ptr(p+0x100),data,len);
    *ptr(p+0x1800)=0xff;
    desc(id*3,p,16,1,id*3+1);
    desc(id*3+1,p+0x100,len,(uint16_t)(1|(type==0?2:0)),id*3+2);
    desc(id*3+2,p+0x1800,1,2,0);
    return p;
}
static void offer(HvVirtioBlk *b,unsigned id) {
    uint16_t *a=(void*)(memory+0x2000);
    uint16_t idx=__atomic_load_n(&a[1],__ATOMIC_RELAXED);
    a[2+idx%256]=(uint16_t)(id*3);
    __atomic_store_n(&a[1],(uint16_t)(idx+1),__ATOMIC_RELEASE);
    b->vio.notify(&b->vio,0);
}
static void setup(HvVirtioBlk *b) {
    memset(memory,0,sizeof memory);
    b->vio.q[0]=(HvVirtq){.size=256,.enabled=1,.desc=BASE,.avail=BASE+0x2000,.used=BASE+0x3000};
    b->vio.driver_features=b->vio.features;
}
static void complete(HvVirtioBlk *b,unsigned id,int status) {
    hv_virtio_blk_drain(b);
    if(status>=0)check(*ptr(BASE+0x10000+id*0x2000+0x1800)==status,"request status");
}
static void verify_file(int fd,const char *why) {
    check(pread(fd,actual,TOTAL,0)==TOTAL,"fixture read");
    check(!memcmp(actual,expected,TOTAL),why);
}
static void seed(int fd) {
    for(size_t i=0;i<TOTAL;i++)expected[i]=(uint8_t)(1+(i*17+13)%255);
    check(pwrite(fd,expected,TOTAL,0)==TOTAL,"fixture seed");
}
static void expect_zero(uint64_t sector,uint32_t n) { memset(expected+PREFIX+sector*512,0,(size_t)n*512); }
struct Range {uint64_t sector;uint32_t num,flags;};
static void discard_case(HvVirtioBlk *b,int fd,const char *label,const struct Range *r,unsigned n,int status) {
    request(0,11,0,r,n*sizeof *r);offer(b,0);complete(b,0,status);
    if(!status)for(unsigned i=0;i<n;i++)expect_zero(r[i].sector,r[i].num);
    verify_file(fd,label);
}
static uint32_t cfg32(HvVirtioBlk *b,unsigned off) {uint32_t x;memcpy(&x,b->vio.config+off,4);return x;}
static void wait_gate(void) {
    struct timespec until;clock_gettime(CLOCK_REALTIME,&until);until.tv_sec+=3;
    pthread_mutex_lock(&gate_mu);
    while(!entered)if(pthread_cond_timedwait(&gate_cv,&gate_mu,&until)!=0)check(0,"writer gate deadline");
    check(1,"writer entered gate before deadline");
    pthread_mutex_unlock(&gate_mu);
}
static void wait_fence(HvVirtioBlk *b) {
    for(unsigned i=0;i<3000;i++) {
        pthread_mutex_lock(&b->mu);int fenced=b->fence;pthread_mutex_unlock(&b->mu);
        if(fenced){check(1,"discard claimed fence while earlier write blocked");return;}
        usleep(1000);
    }
    check(0,"discard fence deadline");
}
int main(void) {
    alarm(20);
    char path[]="/tmp/henge-discard-fixture-XXXXXX";
    int fd=mkstemp(path);check(fd>=0,"temporary fixture");seed(fd);
    HvDisk disk;check(!hv_disk_open(&disk,path,PREFIX,0),"offset disk open");
    HvVirtioBlk *b=hv_virtio_blk_create(&machine,NULL,&disk,HV_VBLK_AUX);setup(b);
    check((b->vio.features&F_DISCARD)!=0,"writable aux advertises discard");
    check(cfg32(b,36)==65536&&cfg32(b,40)==8&&cfg32(b,44)==1,"explicit discard limits");
    check(cfg32(b,60)==HV_VBLK_AUX,"Apple auxiliary role unchanged");
    /* Exercise the largest advertised range, including repeated backend chunks,
       with guard bytes immediately before and after the auxiliary address space. */
    const uint64_t max_bytes=65536ull*512;
    check(!ftruncate(fd,(off_t)(PREFIX+max_bytes+512)),"extend isolated maximum-range fixture");
    disk.size=max_bytes+512;
    uint8_t block[65536];memset(block,0x96,sizeof block);
    for(uint64_t off=0;off<max_bytes+512;off+=sizeof block) {
        size_t n=max_bytes+512-off<sizeof block?(size_t)(max_bytes+512-off):sizeof block;
        check(pwrite(fd,block,n,(off_t)(PREFIX+off))==(ssize_t)n,"seed maximum-range chunk");
    }
    struct Range maximum={0,65536,0};request(0,11,0,&maximum,sizeof maximum);offer(b,0);complete(b,0,0);
    memset(block,0,sizeof block);uint8_t readblock[65536];
    for(uint64_t off=0;off<max_bytes;off+=sizeof block) {
        check(pread(fd,readblock,sizeof readblock,(off_t)(PREFIX+off))==sizeof readblock,"read maximum-range chunk");
        check(!memcmp(readblock,block,sizeof block),"maximum-range zero bytes");
    }
    check(pread(fd,readblock,PREFIX,0)==PREFIX&&!memcmp(readblock,expected,PREFIX),"maximum-range prefix retained");
    check(pread(fd,readblock,512,(off_t)(PREFIX+max_bytes))==512,"maximum-range tail read");
    memset(block,0x96,512);check(!memcmp(readblock,block,512),"maximum-range tail retained");
    maximum.num=65537;request(0,11,0,&maximum,sizeof maximum);offer(b,0);complete(b,0,1);
    check(pread(fd,readblock,512,(off_t)(PREFIX+max_bytes))==512&&!memcmp(readblock,block,512),"over-limit range rejected before writing tail");
    check(!ftruncate(fd,TOTAL),"restore fixture size");disk.size=DISK_BYTES;seed(fd);
    struct Range r[9]={{8,8,0},{31,3,0}};
    discard_case(b,fd,"two valid ranges preserve adjacent data and prefix",r,2,0);
    r[0]=(struct Range){SECTORS-1,1,0};discard_case(b,fd,"last sector boundary",r,1,0);
    r[0]=(struct Range){SECTORS,0,0};discard_case(b,fd,"zero-length range at end",r,1,0);
    r[0]=(struct Range){8,5,0};r[1]=(struct Range){10,4,0};discard_case(b,fd,"overlapping valid ranges",r,2,0);
    for(unsigned i=0;i<8;i++)r[i]=(struct Range){40+i*2,1,0};
    discard_case(b,fd,"advertised eight-range limit",r,8,0);
    r[0]=(struct Range){70,1,0};r[1]=(struct Range){SECTORS,1,0};
    discard_case(b,fd,"invalid later range writes nothing",r,2,1);
    r[1]=(struct Range){80,1,1};discard_case(b,fd,"unmap flag rejected atomically",r,2,2);
    r[1].flags=0x80000000;discard_case(b,fd,"unknown flag rejected atomically",r,2,2);
    r[1]=(struct Range){UINT64_MAX,2,0};discard_case(b,fd,"sector multiplication overflow rejected",r,2,1);
    r[1]=(struct Range){1,UINT32_MAX,0};discard_case(b,fd,"range/limit overflow rejected",r,2,1);
    r[1]=(struct Range){SECTORS+1,0,0};discard_case(b,fd,"empty out-of-bounds range rejected",r,2,1);
    for(unsigned i=0;i<9;i++)r[i]=(struct Range){100+i,1,0};
    discard_case(b,fd,"too many ranges rejected atomically",r,9,1);
    uint64_t p=request(0,11,0,r,15);offer(b,0);complete(b,0,1);verify_file(fd,"truncated range writes nothing");
    request(0,11,0,r,0);offer(b,0);complete(b,0,1);verify_file(fd,"empty payload rejected");
    request(0,11,0,r,16);desc(1,UINT64_MAX-7,16,1,2);offer(b,0);complete(b,0,1);verify_file(fd,"wrapped guest address writes nothing");
    request(0,11,0,r,16);desc(1,BASE+RAM_BYTES-8,16,1,2);offer(b,0);complete(b,0,1);verify_file(fd,"unmapped payload writes nothing");
    request(0,11,0,r,16);desc(2,BASE+RAM_BYTES,1,2,0);offer(b,0);complete(b,0,-1);verify_file(fd,"unmapped status prevents disk write");
    request(0,11,0,r,16);desc(1,p+0x100,16,3,2);offer(b,0);complete(b,0,1);verify_file(fd,"writable payload rejected");
    request(0,11,0,r,16);desc(1,p+0x100,UINT32_MAX,1,2);offer(b,0);complete(b,0,1);verify_file(fd,"oversized descriptor rejected");
    b->vio.driver_features&=~F_DISCARD;discard_case(b,fd,"unnegotiated discard unsupported",r,1,2);b->vio.driver_features|=F_DISCARD;
    uint64_t oldoff=disk.offset;disk.offset=UINT64_MAX;discard_case(b,fd,"file offset overflow rejected",r,1,1);disk.offset=oldoff;
    int oldfd=disk.fd;disk.fd=-1;discard_case(b,fd,"backend error propagated",r,1,1);disk.fd=oldfd;

    /* Valid header/range split across several readable descriptors. */
    p=request(0,11,0,r,16);
    desc(0,p,7,1,1);desc(1,p+7,9,1,2);desc(2,p+0x100,5,1,3);desc(3,p+0x105,11,1,4);desc(4,p+0x1800,1,2,0);
    offer(b,0);complete(b,0,0);expect_zero(r[0].sector,r[0].num);verify_file(fd,"scatter-gather range accepted");

    /* An I/O failure can partially complete a multi-range request (virtio spec).
       The parser rejects malformed requests before writing; backend failures
       cannot offer transaction rollback. */
    r[0]=(struct Range){120,1,0};r[1]=(struct Range){122,1,0};
    fail_at=2;write_calls=0;request(0,11,0,r,32);offer(b,0);complete(b,0,1);fail_at=0;
    expect_zero(120,1);verify_file(fd,"partial backend failure returns IOERR without false rollback claim");

    /* Force ordering, not a timing-based race: hold an earlier OUT in pwrite,
       wait until DISCARD owns its fence, queue following OUT+FLUSH+IN, release.
       The read must see zeros except the subsequent OUT's sector. */
    uint8_t data[4096];memset(data,0xa5,sizeof data);
    pthread_mutex_lock(&gate_mu);delay_next=1;entered=release_gate=0;pthread_mutex_unlock(&gate_mu);
    request(0,1,200,data,sizeof data);offer(b,0);wait_gate();
    r[0]=(struct Range){200,8,0};request(1,11,0,r,16);offer(b,1);wait_fence(b);
    memset(data,0x3c,512);request(2,1,202,data,512);offer(b,2);
    request(3,4,0,NULL,0);offer(b,3);request(4,0,200,NULL,4096);offer(b,4);
    pthread_mutex_lock(&gate_mu);release_gate=1;pthread_cond_broadcast(&gate_cv);pthread_mutex_unlock(&gate_mu);
    for(unsigned i=0;i<5;i++)complete(b,i,0);
    expect_zero(200,8);memset(expected+PREFIX+202*512,0x3c,512);
    check(!memcmp(ptr(BASE+0x10000+4*0x2000+0x100),expected+PREFIX+200*512,4096),"ordered read sees discard then later write");
    check(flush_calls>0,"real flush retained");verify_file(fd,"ordered writes preserve surrounding disk");
    int reopened=open(path,O_RDONLY);check(reopened>=0,"reopen fixture");verify_file(reopened,"flushed data persists after reopen");close(reopened);

    HvVirtioBlk *plain=hv_virtio_blk_create(&machine,NULL,&disk,HV_VBLK_PLAIN);
    HvVirtioBlk *root=hv_virtio_blk_create(&machine,NULL,&disk,HV_VBLK_ROOT);
    check(!(plain->vio.features&F_DISCARD)&&!cfg32(plain,36),"plain device unchanged");
    check(!(root->vio.features&F_DISCARD)&&!cfg32(root,36),"root device unchanged");
    setup(root);discard_case(root,fd,"root discard unsupported",r,1,2);
    HvDisk ro;check(!hv_disk_open(&ro,path,PREFIX,1),"read-only backend");
    HvVirtioBlk *readonly=hv_virtio_blk_create(&machine,NULL,&ro,HV_VBLK_AUX);
    check(!(readonly->vio.features&F_DISCARD)&&!cfg32(readonly,36),"read-only aux does not advertise discard");
    setup(readonly);discard_case(readonly,fd,"read-only discard rejects without writes",r,1,1);
    hv_disk_close(&ro);hv_disk_close(&disk);close(fd);unlink(path);
    printf("PASS %d checks: real virtqueue/worker/file discard, malformed requests, limits, errors, ordering, prefix preservation\n",checks);
    return 0;
}
