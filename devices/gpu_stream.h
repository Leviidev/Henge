#ifndef HENGE_GPU_STREAM_H
#define HENGE_GPU_STREAM_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    const uint8_t *bytes;
    size_t start, end;
    uint32_t type, continuation, more, declared;
} HvGpuSegment;
typedef struct { const uint8_t *bytes; size_t size, offset; uint32_t tag; } HvGpuRecord;
typedef struct {
    unsigned reason;
    uint32_t type, tag;
    size_t offset, needed, available;
} HvGpuReject;
enum { HV_GPU_OK, HV_GPU_HEADER, HV_GPU_RECORD, HV_GPU_ENCODER,
       HV_GPU_TAG, HV_GPU_PAYLOAD, HV_GPU_EMPTY, HV_GPU_REASON_COUNT };
static inline bool hv_gpu_reject(HvGpuReject *out,unsigned reason,uint32_t type,uint32_t tag,
                                 size_t off,size_t needed,size_t available) {
    if(out)*out=(HvGpuReject){reason,type,tag,off,needed,available};
    return false;
}
static inline bool hv_gpu_segment(const void *data,size_t size,HvGpuSegment *out,HvGpuReject *why) {
    const uint8_t *p=data;
    if(!p||size<8)return hv_gpu_reject(why,HV_GPU_HEADER,0,0,0,8,size);
    uint32_t len,info;memcpy(&len,p,4);memcpy(&info,p+4,4);size_t start=8;
    if((info&255)==5) {
        if(size<24)return hv_gpu_reject(why,HV_GPU_HEADER,5,0,8,24,size);
        memcpy(&len,p+16,4);memcpy(&info,p+20,4);start=24;
    }
    /* Driver descriptors bound the copy. Like the existing replay, accept a
       declared length including its envelope or backing allocation padding;
       never read beyond the copied bytes. Both backends use this exact view. */
    size_t payload=size-start;
    if(len<payload)payload=len;
    *out=(HvGpuSegment){p,start,start+payload,info&255,(info>>8)&255,(info>>16)&255,len};
    return true;
}
static inline bool hv_gpu_zero_tail(const uint8_t *p,size_t n) {
    while(n--)if(*p++)return false;
    return true;
}
/* 1: record; 0: end/zero allocation padding; -1: malformed. */
static inline int hv_gpu_next(const HvGpuSegment *s,size_t *at,HvGpuRecord *r,HvGpuReject *why) {
    if(*at>s->end){hv_gpu_reject(why,HV_GPU_RECORD,s->type,0,*at,0,0);return -1;}
    size_t left=s->end-*at;
    if(!left)return 0;
    if(left<8) {
        if(hv_gpu_zero_tail(s->bytes+*at,left)){*at=s->end;return 0;}
        hv_gpu_reject(why,HV_GPU_RECORD,s->type,0,*at,8,left);return -1;
    }
    uint32_t tag,n;memcpy(&tag,s->bytes+*at,4);memcpy(&n,s->bytes+*at+4,4);
    if(!tag&&!n&&hv_gpu_zero_tail(s->bytes+*at,left)){*at=s->end;return 0;}
    if(n<8||n>left){hv_gpu_reject(why,HV_GPU_RECORD,s->type,tag,*at,n,left);return -1;}
    *r=(HvGpuRecord){s->bytes+*at+8,n-8,*at,tag};*at+=n;return 1;
}
#endif
