/* Exercise the production vectored transfer cursor, plus real temporary-file
   scatter/gather. Syscall boundaries alone are injected in the first section. */
#define _DEFAULT_SOURCE 1
#include "disk.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static ssize_t (*const real_readv)(int,const struct iovec *,int,off_t)=preadv;
static ssize_t (*const real_writev)(int,const struct iovec *,int,off_t)=pwritev;
static unsigned calls;
static uint64_t progress;
static int mode, writing_fd=171, payload=1;
static ssize_t transfer(int fd,const struct iovec *iov,int count,off_t offset,int writing) {
    if(mode==5)return writing?real_writev(fd,iov,count,offset):real_readv(fd,iov,count,offset);
    assert(fd==(writing?writing_fd:171));calls++;
    assert(count>0 && count<=HV_DISK_IOV_MAX && (uint64_t)offset==4096+progress);
    size_t total=0;for(int i=0;i<count;i++){assert(iov[i].iov_len);total+=iov[i].iov_len;}
    assert(total>0 && total<=128u<<20);
    if(mode==1 && (calls==1 || calls==4)){errno=EINTR;return -1;}
    if(mode==2)return 0;
    if(mode==3 || (mode==4 && calls>1)){errno=EIO;return -1;}
    size_t n=(mode==1 && calls==2)||mode==4 ? 7 : mode==1&&calls==3 ? 13 : total;
    if(n>total)n=total;
    size_t remaining=n,at=0;
    for(int i=0;i<count&&remaining;i++) {
        size_t part=iov[i].iov_len<remaining?iov[i].iov_len:remaining;
        if(payload)for(size_t j=0;j<part;j++) {
            unsigned char value=(unsigned char)(progress+at+j);
            if(writing)assert(((unsigned char *)iov[i].iov_base)[j]==value);
            else ((unsigned char *)iov[i].iov_base)[j]=value;
        }
        remaining-=part;at+=part;
    }
    progress+=n;return (ssize_t)n;
}
static ssize_t fake_readv(int fd,const struct iovec *iov,int count,off_t off){return transfer(fd,iov,count,off,0);}
static ssize_t fake_writev(int fd,const struct iovec *iov,int count,off_t off){return transfer(fd,iov,count,off,1);}
#define preadv fake_readv
#define pwritev fake_writev
#include "../host/disk.c"
#undef preadv
#undef pwritev
int hv_knob[HV_K_COUNT];
int main(void) {
    unsigned char a[16],b[64],c[32];memset(a,0xaa,sizeof a);memset(b,0xaa,sizeof b);memset(c,0xaa,sizeof c);
    struct iovec iov[]={{a+1,15},{NULL,0},{b+3,45},{c+2,30}};
    struct iovec original[4];memcpy(original,iov,sizeof iov);
    HvDisk disk={.fd=171,.wfd=-1,.offset=4096,.size=90};
    mode=1;assert(!hv_disk_readv(&disk,0,iov,4) && progress==90 && calls==5);
    assert(a[0]==0xaa && b[0]==0xaa && b[48]==0xaa && c[0]==0xaa);
    assert(!memcmp(iov,original,sizeof iov));
    progress=0;calls=0;assert(!hv_disk_writev(&disk,0,iov,4) && progress==90 && calls==5);
    disk.wfd=writing_fd=77;progress=0;calls=0;mode=0;
    assert(!hv_disk_writev(&disk,0,iov,4) && calls==1 && progress==90);
    disk.wfd=-1;writing_fd=171;
    calls=0;assert(hv_disk_readv(&disk,1,iov,4)==-1 && !calls);
    assert(hv_disk_readv(&disk,UINT64_MAX,iov,4)==-1 && !calls);
    assert(hv_disk_readv(&disk,0,NULL,1)==-1 && !calls);
    assert(hv_disk_readv(&disk,0,iov,-1)==-1 && !calls);
    assert(hv_disk_readv(&disk,0,iov,HV_DISK_IOV_MAX+1)==-1 && !calls);
    disk.readonly=1;assert(hv_disk_writev(&disk,0,iov,4)==-1 && !calls);disk.readonly=0;
    assert(!hv_disk_readv(&disk,90,NULL,0) && !calls);
    disk.offset=INT64_MAX;assert(hv_disk_readv(&disk,0,iov,4)==-1 && !calls);disk.offset=4096;
    struct iovec overflow[]={{a,SIZE_MAX},{b,1}};
    assert(hv_disk_readv(&disk,0,overflow,2)==-1 && !calls);
    for(mode=2;mode<=4;mode++) {
        calls=0;progress=0;assert(hv_disk_readv(&disk,0,iov,4)==-1);
        assert(calls==(mode==4?2u:1u));
    }
    /* A transfer larger than the syscall ceiling crosses vector boundaries,
       while a short transfer inside a vector retains the same file cursor. */
    unsigned char *large=malloc((272u<<20)+64);assert(large);
    struct iovec big[]={{large,90u<<20},{large+(90u<<20)+16,90u<<20},{large+(180u<<20)+32,90u<<20}};
    disk.size=270u<<20;mode=0;payload=0;calls=0;progress=0;
    assert(!hv_disk_readv(&disk,0,big,3) && calls==3 && progress==270u<<20);
    free(large);
    /* Real file, preserved auxiliary prefix, disjoint buffers, no staging. */
    char path[]="/tmp/henge-iov-XXXXXX";int fd=mkstemp(path);assert(fd>=0);unlink(path);
    assert(!ftruncate(fd,8192));unsigned char prefix[4096];memset(prefix,0xd5,sizeof prefix);assert(pwrite(fd,prefix,sizeof prefix,0)==sizeof prefix);
    disk=(HvDisk){.fd=fd,.wfd=-1,.offset=4096,.size=4096};mode=5;
    for(int i=0;i<4;i++)for(size_t j=0;j<iov[i].iov_len;j++)((unsigned char *)iov[i].iov_base)[j]=(unsigned char)(i*31+j);
    unsigned char expected[90];size_t pos=0;
    for(int i=0;i<4;i++){if(iov[i].iov_len)memcpy(expected+pos,iov[i].iov_base,iov[i].iov_len);pos+=iov[i].iov_len;}
    assert(!hv_disk_writev(&disk,2048,iov,4));unsigned char check[90];assert(pread(fd,check,sizeof check,6144)==sizeof check && !memcmp(check,expected,sizeof check));
    for(int i=0;i<4;i++)if(iov[i].iov_len)memset(iov[i].iov_base,0,iov[i].iov_len);
    assert(!hv_disk_readv(&disk,2048,iov,4));pos=0;
    for(int i=0;i<4;i++){if(iov[i].iov_len)assert(!memcmp(iov[i].iov_base,expected+pos,iov[i].iov_len));pos+=iov[i].iov_len;}
    unsigned char saved[4096];assert(pread(fd,saved,sizeof saved,0)==sizeof saved && !memcmp(saved,prefix,sizeof prefix));close(fd);
    puts("PASS disk vectors: scattered buffers / 1 syscall, immutable vectors, EINTR, partial/error/EOF, 128MiB chunks, bounds/overflow/read-only and real auxiliary-offset I/O");
}
