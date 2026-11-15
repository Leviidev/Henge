#ifndef HENGE_GPU_REJECT_STATS_H
#define HENGE_GPU_REJECT_STATS_H
#include "gpu_stream.h"

/* Owned by the replay worker, like the existing rejection counters. Fixed
   storage, no allocation and no timer. Preserve overflow explicitly rather
   than pretending the last rejected opcode describes all classic replay. */
#define HV_GPU_REJECT_BUCKETS 32
typedef struct {
    unsigned reason;
    uint32_t type,tag;
    size_t min_bytes,max_bytes;
    uint64_t count;
} HvGpuRejectBucket;
typedef struct {
    unsigned used;
    uint64_t overflow;
    HvGpuRejectBucket buckets[HV_GPU_REJECT_BUCKETS];
} HvGpuRejectStats;
static inline void hv_gpu_reject_note(HvGpuRejectStats *stats,HvGpuReject rejection) {
    for(unsigned i=0;i<stats->used;i++) {
        HvGpuRejectBucket *b=&stats->buckets[i];
        if(b->reason!=rejection.reason||b->type!=rejection.type||b->tag!=rejection.tag)continue;
        b->count++;
        if(rejection.available<b->min_bytes)b->min_bytes=rejection.available;
        if(rejection.available>b->max_bytes)b->max_bytes=rejection.available;
        return;
    }
    if(stats->used==HV_GPU_REJECT_BUCKETS){stats->overflow++;return;}
    stats->buckets[stats->used++]=(HvGpuRejectBucket){rejection.reason,rejection.type,rejection.tag,rejection.available,rejection.available,1};
}
/* Rank is used only at the existing diagnostic checkpoint. Stable ties keep
   distinct commands visible without sorting or mutating worker counters. */
static inline const HvGpuRejectBucket *hv_gpu_reject_top(const HvGpuRejectStats *stats,unsigned rank) {
    if(rank>=stats->used)return NULL;
    for(unsigned i=0;i<stats->used;i++) {
        unsigned greater=0;
        for(unsigned j=0;j<stats->used;j++)
            greater+=stats->buckets[j].count>stats->buckets[i].count||
                (stats->buckets[j].count==stats->buckets[i].count&&j<i);
        if(greater==rank)return &stats->buckets[i];
    }
    return NULL;
}
#endif
