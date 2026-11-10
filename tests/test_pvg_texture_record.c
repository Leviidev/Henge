#include "../devices/pvg_texture_record.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

/* Actual mapped records from the same 420f surface in the guest's Core Image
   White Rose decode. The RG8 chroma view requests plane 1 in the last word. */
static const uint8_t luma[] = {
  6,0,0,0,0,0,0,0, 0x2f,0,0,0,48,0,0,0,10,0,0,0,
  0x42,1,10,0,0,2,0,0,0,2,0,0,1,0,0,0,1,0,1,0,1,0,16,0,
  0,0,0,0,0,0,0,0,0,0,0,0
};
static const uint8_t chroma[] = {
  6,0,0,0,0,0,0,0, 0x2f,0,0,0,48,0,0,0,11,0,0,0,
  0x42,1,30,0,0,1,0,0,0,1,0,0,1,0,0,0,1,0,1,0,1,0,16,0,
  0,0,0,0,0,0,0,0,1,0,0,0
};
int main(void) {
    HvMappedTextureRecord out;
    assert(sizeof(luma)==56 && sizeof(chroma)==56);
    assert(hv_pvg_decode_mapped_texture(luma,sizeof(luma),&out));
    assert(out.mapping==6 && out.reference==10 && out.plane==0 && out.descriptor==luma+20);
    assert(hv_pvg_decode_mapped_texture(chroma,sizeof(chroma),&out));
    assert(out.mapping==6 && out.reference==11 && out.plane==1 && out.descriptor_size==48);
    for (size_t n=0;n<sizeof(chroma);n++) assert(!hv_pvg_decode_mapped_texture(chroma,n,&out));
    uint8_t altered[64]={0};memcpy(altered,chroma,sizeof(chroma));
    altered[12]=49;assert(!hv_pvg_decode_mapped_texture(altered,sizeof(altered),&out));
    altered[12]=48;altered[8]=0xff;assert(!hv_pvg_decode_mapped_texture(altered,sizeof(altered),&out));
    /* Layout/bounds check for v2; not a claim of v2 device execution. */
    altered[8]=0x39;altered[12]=56;altered[52]=0;altered[60]=1;
    for(size_t n=56;n<64;n++)assert(!hv_pvg_decode_mapped_texture(altered,n,&out));
    assert(hv_pvg_decode_mapped_texture(altered,sizeof(altered),&out) && out.plane==1);
    assert(!hv_pvg_decode_mapped_texture(NULL,sizeof(altered),&out));
    assert(!hv_pvg_decode_mapped_texture(altered,sizeof(altered),NULL));
    puts("Captured plane selection and truncated/unknown record checks passed");
}
