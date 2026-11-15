/* Actual schema3 chunk encoder/decoder. Link dead-strips unrelated VM entrypoints. */
#define HV_SNAPSHOT_TESTING 1
#include "../host/snapshot.c"
#include <assert.h>

static void roundtrip(Slot *slot, uint8_t *ram, uint8_t *copy, uint64_t size, unsigned index, int dense) {
    memset(copy,0,(size_t)size);
    chunk_pack(slot,ram,size,index,0,NULL);
    if (dense) assert(slot->raw_source==ram+(uint64_t)index*CHUNK_BYTES);
    else assert(slot->raw_source==slot->stage);
    if (slot->h.raw) memcpy(slot->out,slot->raw_source,slot->h.bytes);
    assert(!chunk_unpack(slot,copy,size));
    uint64_t from=(uint64_t)index*CHUNK_BYTES;
    size_t n=(size_t)(size-from<CHUNK_BYTES?size-from:CHUNK_BYTES);
    assert(!memcmp(ram+from,copy+from,n));
    slot->h.checksum^=1;
    assert(chunk_unpack(slot,copy,size)==-1);
    slot->h.checksum^=1;
}
static int cancelled_always(void *ctx) { (void)ctx;return 1; }
int main(void) {
    assert(hv_snapshot_workers(0,0)==1);
    assert(hv_snapshot_workers(10,UINT64_MAX)==8);
    assert(hv_snapshot_workers(10,128ull<<20)==4);
    assert(hv_snapshot_workers(4,80ull<<20)==1);
    assert(hv_snapshot_workers(2,UINT64_MAX)==2);
    Slot slot={0};assert(!slots_alloc(&slot,1));
    size_t size=CHUNK_BYTES+3*PAGE;
    uint8_t *ram=calloc(1,size),*copy=calloc(1,size);assert(ram&&copy);
    roundtrip(&slot,ram,copy,size,0,0); /* zero bitmap */
    memset(ram,0x5a,size);
    roundtrip(&slot,ram,copy,size,0,1); /* dense compressed borrows RAM */
    assert(!slot.h.raw&&!slot.compression_probe_skipped);
    roundtrip(&slot,ram,copy,size,1,1); /* partial last chunk */
    uint32_t state=0x87654321;
    for(size_t i=0;i<size;i++) {state^=state<<13;state^=state>>17;state^=state<<5;ram[i]=(uint8_t)state;}
    roundtrip(&slot,ram,copy,size,0,1);assert(slot.h.raw&&slot.compression_probe_skipped); /* uncompressible borrowed write */
    /* A compressible spread-out sample keeps full compression active, even
       when the first sample is random. No first-page-only entropy guess. */
    memset(ram+CHUNK_BYTES-PAGE,0x5a,PAGE);
    roundtrip(&slot,ram,copy,size,0,1);assert(!slot.compression_probe_skipped);
    for(unsigned i=0;i<CHUNK_PAGES;i+=2)memset(ram+(size_t)i*PAGE,0,PAGE);
    roundtrip(&slot,ram,copy,size,0,0); /* sparse compaction, unchanged disk schema */
    HvSnapshotControl control={.cancelled=cancelled_always};
    chunk_pack(&slot,ram,size,0,0,&control);assert(!slot.h.stored&&!slot.h.bytes);
    FILE *file=tmpfile();assert(file);
    uint64_t stored=0;
    HvSnapshotControl limited={.workers=2};
    W writer={.fd=fileno(file),.buf=malloc(CHUNK_BYTES),.cap=CHUNK_BYTES,.control=&limited};assert(writer.buf);
    HvRam source={.pa=0x100000,.size=size,.host=ram};
    assert(!save_ram(&writer,&source,&stored,1));w_flush(&writer);assert(!writer.err);free(writer.buf);
    assert(lseek(fileno(file),0,SEEK_SET)==0);memset(copy,0,size);
    R reader={.fd=fileno(file),.buf=malloc(CHUNK_BYTES),.cap=CHUNK_BYTES};assert(reader.buf);
    HvRam destination={.pa=source.pa,.size=size,.host=copy};
    hv_snapshot_test_fail_after(0);
    assert(!load_ram(&reader,&destination));
    assert(hv_snapshot_test_packing_retries()>0);
    hv_snapshot_test_fail_after(-1);
    assert(!memcmp(ram,copy,size));free(reader.buf);fclose(file);
    slots_free(&slot,1);free(ram);free(copy);
    puts("Snapshot chunks: dense/sparse/zero/raw/partial, corruption, cancellation and memory budgets passed");
    return 0;
}
