#include "../devices/panic_candidates.h"
#include <assert.h>
#include <stdlib.h>
int main(void){
    uint8_t ram[4096]={0};HvPanicCandidate c[4];
    const char *old="panic(cpu 1 caller 0xfffffe0012345678): old filesystem error\nDebugger message: panic\nKernel: old\n";
    const char *fresh="panic(cpu 2 caller 0xfffffe0087654321): different current error\nDebugger message: panic\nKernel: current\n";
    memcpy(ram+20,old,strlen(old));memcpy(ram+500,fresh,strlen(fresh));memcpy(ram+1000,old,strlen(old));
    memset(ram+1200,'x',300);memcpy(ram+1200,"panic(cpu %u caller 0x%llx):",26);
    size_t n=hv_panic_candidates(ram,sizeof ram,c,4);assert(n==2);
    assert(c[0].text==ram+20&&c[1].text==ram+500);
    assert(c[0].length==strlen(old)&&c[1].length==strlen(fresh));
    assert(hv_panic_candidates(NULL,0,c,4)==0);
    assert(hv_panic_candidates(ram,25,c,4)==0);
    /* A non-NUL-terminated valid report ending exactly at the memory bound. */
    n=hv_panic_candidates((const uint8_t *)fresh,strlen(fresh),c,4);
    assert(n==1&&c[0].length==strlen(fresh));
    puts("panic candidates: old/new/duplicate/template/truncated/boundary checks passed");
}
