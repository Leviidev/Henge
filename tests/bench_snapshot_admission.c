#define HV_SNAPSHOT_TESTING 1
#include "../host/snapshot.c"
#include <assert.h>
int main(void) {
    Slot slot={0};assert(!slots_alloc(&slot,1));
    uint8_t *ram=malloc(CHUNK_BYTES),*copy=malloc(CHUNK_BYTES);assert(ram&&copy);
    const char *names[]={"random","flat","mixed"};
    for(unsigned pattern=0;pattern<3;pattern++) {
        uint32_t seed=0x12347983;
        for(size_t i=0;i<CHUNK_BYTES;i++){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;ram[i]=pattern==1?0x4b:(uint8_t)seed;}
        if(pattern==2)memset(ram+CHUNK_BYTES-1024*1024,0x4b,1024*1024);
        for(unsigned round=0;round<3;round++)for(unsigned k=0;k<2;k++) {
            unsigned adaptive=k^(round&1);snapshot_force_full_compression=!adaptive;
            double begin=mono();
            for(unsigned i=0;i<8;i++)chunk_pack(&slot,ram,CHUNK_BYTES,0,0,NULL);
            double seconds=mono()-begin;
            if(slot.h.raw)memcpy(slot.out,slot.raw_source,slot.h.bytes);
            memset(copy,0,CHUNK_BYTES);assert(!chunk_unpack(&slot,copy,CHUNK_BYTES));
            assert(!memcmp(ram,copy,CHUNK_BYTES));
            assert(slot.compression_probe_skipped==(adaptive&&pattern==0));
            printf("snapshot-admission-bench: pattern=%s round=%u adaptive=%u ms_per_4MiB=%.3f encoded_bytes=%u raw=%u lossless=1\n",names[pattern],round,adaptive,seconds*1000/8,slot.h.bytes,slot.h.raw);
        }
    }
    free(ram);free(copy);slots_free(&slot,1);
    puts("PASS snapshot raw admission: paired production packing, random/flat/mixed data and bit-exact decode");
    return 0;
}
