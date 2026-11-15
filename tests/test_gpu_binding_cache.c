#include "../devices/gpu_binding_cache.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
int main(void) {
    HvBindingCache *c=calloc(1,sizeof *c); assert(c);
    struct { uint64_t op, first, count, object, offset, stride; } k={125,0,1,17,0,0};
    assert(hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    assert(!hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    k.offset=16; assert(hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    k.offset=0; assert(hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    k.first=1; assert(hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    k.first=0; assert(hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    k.op=165; k.stride=16; assert(hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    k.stride=32; assert(hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    k.object=0; assert(hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    assert(!hv_binding_update(c,HV_BIND_VERTEX_BUFFER,&k,sizeof k));
    assert(hv_binding_update(c,HV_BIND_FRAGMENT_BUFFER,&k,sizeof k));
    hv_binding_reset(c); assert(hv_binding_update(c,HV_BIND_FRAGMENT_BUFFER,&k,sizeof k));
    assert(hv_binding_update(c,HV_BIND_FRAGMENT_BUFFER,NULL,0));
    assert(hv_binding_update(c,HV_BIND_FRAGMENT_BUFFER,&k,sizeof k));
    assert(hv_binding_update(c,HV_BIND_FRAGMENT_BUFFER,&k,HV_BIND_KEY_BYTES+1));
    assert(hv_binding_update(c,HV_BIND_FRAGMENT_BUFFER,&k,sizeof k));
    for(int i=0;i<100000;i++)assert(!hv_binding_update(c,HV_BIND_FRAGMENT_BUFFER,&k,sizeof k));
    c->disabled=true;assert(hv_binding_update(c,HV_BIND_FRAGMENT_BUFFER,&k,sizeof k));
    assert(c->skipped==100002);
    free(c);puts("GPU binding cache: exact identities, range/offset/stride/nil changes, encoder resets, disabled reference and 100000 repeated calls passed");
}
