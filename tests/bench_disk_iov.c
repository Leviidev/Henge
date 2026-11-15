/* Paired warm-file syscall benchmark. Host I/O microbenchmark only: no guest
   FPS, storage cold-cache latency, GPU or energy claim. */
#define _DEFAULT_SOURCE 1
#include "disk.h"
#include "machine.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
int hv_knob[HV_K_COUNT];
static uint64_t nanos(void){struct timespec ts;assert(!clock_gettime(CLOCK_MONOTONIC,&ts));return (uint64_t)ts.tv_sec*1000000000+(uint64_t)ts.tv_nsec;}
int main(void) {
    enum { N=32, PAGE=4096, RUNS=2000 };
    unsigned char *bytes=malloc(N*PAGE*2);assert(bytes);memset(bytes,0x8d,N*PAGE*2);
    char path[]="/tmp/henge-iov-bench-XXXXXX";int fd=mkstemp(path);assert(fd>=0);unlink(path);
    assert(pwrite(fd,bytes,N*PAGE,0)==N*PAGE);
    HvDisk disk={.fd=fd,.wfd=-1,.size=N*PAGE};struct iovec iov[N];
    for(int i=0;i<N;i++)iov[i]=(struct iovec){bytes+i*PAGE*2,PAGE};
    for(unsigned round=0;round<5;round++)for(unsigned order=0;order<2;order++) {
        unsigned vector=order^(round&1);
        uint64_t start=nanos();
        for(int n=0;n<RUNS;n++) {
            if(vector)assert(!hv_disk_readv(&disk,0,iov,N));
            else for(int i=0;i<N;i++)assert(!hv_disk_read(&disk,i*PAGE,iov[i].iov_base,PAGE));
        }
        printf("disk-iov-bench: round=%u vectors=%u pages=%d calls_per_request=%d ns_per_request=%.1f runs=%d\n",round,vector,N,vector?1:N,(nanos()-start)/(double)RUNS,RUNS);
        for(int i=0;i<N;i++)assert(((unsigned char *)iov[i].iov_base)[0]==0x8d);
    }
    close(fd);free(bytes);
}
