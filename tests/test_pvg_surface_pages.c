#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "../devices/pvg_surface_pages.h"
static uint32_t tables[9][4096];
static unsigned reads;
static const void *reader(void *context, uint64_t pa, uint64_t length) {
    (void)context; reads++;
    assert(length==0x4000);
    if (pa<0x4000 || pa>=10*0x4000 || pa%0x4000) return NULL;
    return tables[pa/0x4000-1];
}
int main(void) {
    uint32_t *out=malloc(32768*4);
    for (unsigned i=0;i<4096;i++) tables[0][i]=(0x100000+i*4)|1;
    assert(hv_pvg_surface_pages(5,4095,out,NULL,reader));
    assert(hv_pvg_surface_pages(5,4096,out,NULL,reader));
    assert(out[4095]==(0x100000+4095*4+1));
    assert(!hv_pvg_surface_pages(5,4097,out,NULL,reader));
    for (unsigned j=0;j<8;j++) {
        tables[0][j]=((j+2)*4)|3;
        for(unsigned i=0;i<4096;i++) tables[j+1][i]=(0x100000+(j*4096+i)*4)|1;
    }
    const unsigned counts[]={1,4096,4097,8193,8836,32768};
    for(unsigned k=0;k<sizeof counts/sizeof *counts;k++) {
        unsigned n=counts[k];reads=0;
        assert(hv_pvg_surface_pages(5,n,out,NULL,reader));
        assert(reads==1+(n+4095)/4096);
        for(unsigned i=0;i<n;i++)assert(out[i]==(0x100000+i*4+1));
    }
    assert(!hv_pvg_surface_pages(5,32769,out,NULL,reader));
    assert(!hv_pvg_surface_pages(4,4096,out,NULL,reader));
    assert(!hv_pvg_surface_pages(7,4096,out,NULL,reader));
    tables[2][0]=0;assert(!hv_pvg_surface_pages(5,4097,out,NULL,reader));
    tables[2][0]=3;assert(!hv_pvg_surface_pages(5,4097,out,NULL,reader));
    tables[0][1]=0xfffffff3;assert(!hv_pvg_surface_pages(5,4097,out,NULL,reader));
    free(out);puts("surface page decoder: boundary, ordering, and malformed-table cases passed");
}
