#include "gpu_epoch_cache.h"
#include <assert.h>
#include <stdio.h>
int main(void){
 struct HvGpuEpochKey keys[HV_GPU_EPOCH_SLOTS]={0};
 unsigned slot=hv_gpu_epoch_slot(1,7);keys[slot]=(struct HvGpuEpochKey){10,1,7};
 unsigned reads=1,hits=0;
 for(int i=1;i<10000;i++){if(hv_gpu_epoch_match(keys[slot],10,1,7))hits++;else reads++;}
 assert(reads==1 && hits==9999);
 assert(!hv_gpu_epoch_match(keys[slot],11,1,7));assert(!hv_gpu_epoch_match(keys[slot],0,1,7));
 assert(!hv_gpu_epoch_match(keys[slot],10,2,7));
 assert(hv_gpu_epoch_slot(1,71)==slot && !hv_gpu_epoch_match(keys[slot],10,1,71));
 puts("GPU epoch keys: repeated immutable lookup, new commands/tasks, disabled epoch and slot collisions passed");
}
