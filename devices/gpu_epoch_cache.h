#ifndef HENGE_GPU_EPOCH_CACHE_H
#define HENGE_GPU_EPOCH_CACHE_H
#include <stdint.h>
#define HV_GPU_EPOCH_SLOTS 64
struct HvGpuEpochKey { uint64_t epoch; uint32_t task,ref; };
static inline unsigned hv_gpu_epoch_slot(uint32_t task,uint32_t ref){return(ref^(task*2654435761u))&(HV_GPU_EPOCH_SLOTS-1);}
static inline int hv_gpu_epoch_match(struct HvGpuEpochKey k,uint64_t epoch,uint32_t task,uint32_t ref){return epoch && k.epoch==epoch && k.task==task && k.ref==ref;}
#endif
