#ifndef HENGE_PANIC_CANDIDATES_H
#define HENGE_PANIC_CANDIDATES_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { const uint8_t *text; size_t length; } HvPanicCandidate;

/* RAM can contain older panic reports in filesystem caches. Retain several
 * distinct, bounded text candidates; none is implicitly the current panic. */
static size_t hv_panic_candidates(const uint8_t *ram, size_t bytes,
                                  HvPanicCandidate *out, size_t capacity) {
    const char key[]="panic(cpu ";
    if(!ram || !capacity)return 0;
    size_t count=0,offset=0;
    while(offset<bytes){
        const uint8_t *p=memmem(ram+offset,bytes-offset,key,sizeof key-1);
        if(!p)break;
        size_t at=(size_t)(p-ram),n=0;
        while(n<bytes-at && n<3000 && (p[n]=='\n'||p[n]=='\t'||(p[n]>=32&&p[n]<127)))n++;
        offset=at+sizeof key-1;
        if(n<=80)continue;
        char header[160];size_t h=n<sizeof header-1?n:sizeof header-1;
        memcpy(header,p,h);header[h]=0;
        unsigned cpu;unsigned long long caller;int consumed=0;
        if(sscanf(header,"panic(cpu %u caller 0x%llx):%n",&cpu,&caller,&consumed)!=2 || !caller || !consumed)continue;
        size_t i;
        for(i=0;i<count;i++){
            size_t common=n<out[i].length?n:out[i].length;
            if(common>256)common=256;
            if(!memcmp(p,out[i].text,common))break;
        }
        if(i<count){if(n>out[i].length)out[i]=(HvPanicCandidate){p,n};continue;}
        if(count<capacity)out[count++]=(HvPanicCandidate){p,n};
        else {
            size_t shortest=0;for(i=1;i<count;i++)if(out[i].length<out[shortest].length)shortest=i;
            if(n>out[shortest].length)out[shortest]=(HvPanicCandidate){p,n};
        }
    }
    return count;
}
#endif
