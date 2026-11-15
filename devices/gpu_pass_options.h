#ifndef HENGE_GPU_PASS_OPTIONS_H
#define HENGE_GPU_PASS_OPTIONS_H
#include "pvg_store_action.h"
/* Final store options affect the end of a render pass, not its draws.
   Metal4 exposes these on attachment descriptors instead of encoder setters.
   Collect the final values before creating the encoder; verify every replayed
   setter against this plan before submission. All original bytes stay intact. */
typedef struct { uint64_t values[10]; uint16_t mask; } HvGpuPassOptions;
static inline bool hv_gpu_pass_option(HvGpuPassOptions *plan,uint32_t tag,const void *p,size_t n) {
    if(tag!=103&&tag!=106&&tag!=121)return false;
    HvStoreAction a;if(!hv_pvg_decode_store_action(tag,p,n,&a))return false;
    unsigned slot=tag==103?a.index:tag==106?8:9;
    plan->values[slot]=a.value;plan->mask|=(uint16_t)(1u<<slot);return true;
}
static inline bool hv_gpu_pass_options_equal(const HvGpuPassOptions *a,const HvGpuPassOptions *b) {
    if(a->mask!=b->mask)return false;
    for(unsigned i=0;i<10;i++)if((a->mask&(1u<<i))&&a->values[i]!=b->values[i])return false;
    return true;
}
#endif
