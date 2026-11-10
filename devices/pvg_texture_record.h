#ifndef HV_PVG_TEXTURE_RECORD_H
#define HV_PVG_TEXTURE_RECORD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t mapping;
    uint32_t tag, descriptor_size, reference, plane;
    const uint8_t *descriptor;
} HvMappedTextureRecord;

static inline uint32_t hv_pvg_texture_u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* The descriptor size includes its {tag,size,ref} header, but excludes
   the eight-byte surface mapping ID. The last word selects its plane.
   Captured Sonoma records use tag 0x2f/size 48; the swizzle-bearing v2
   record uses tag 0x39/size 56. Reject truncated/unknown forms explicitly. */
static inline bool hv_pvg_decode_mapped_texture(const uint8_t *bytes, size_t length,
                                               HvMappedTextureRecord *out) {
    if (!bytes || !out || length < 20) return false;
    uint32_t tag = hv_pvg_texture_u32(bytes + 8);
    uint32_t size = hv_pvg_texture_u32(bytes + 12);
    uint32_t expected = tag == 0x2f ? 48 : tag == 0x39 ? 56 : 0;
    if (!expected || size != expected || length < (size_t)size + 8) return false;
    *out = (HvMappedTextureRecord){
        .mapping = (uint64_t)hv_pvg_texture_u32(bytes) |
                   (uint64_t)hv_pvg_texture_u32(bytes + 4) << 32,
        .tag = tag, .descriptor_size = size,
        .reference = hv_pvg_texture_u32(bytes + 16),
        .plane = hv_pvg_texture_u32(bytes + 8 + size - 4),
        .descriptor = bytes + 20,
    };
    return true;
}

/* Ordinary texture layout already consumed by makeTexture()/page():
   {u64 backing length,u32 virtual page}, 24-byte layout header, 36 bytes
   per mip, {tag,size,ref}, then descriptor_v1/v2. These are CPU decoders;
   they neither access guest memory nor call Metal. */
typedef struct {
    uint64_t length, base, stride;
    uint32_t page, tag, descriptor_size, reference;
    uint16_t mips, slices;
    uint8_t block_height;
    bool v2;
    const uint8_t *layout, *descriptor;
} HvOrdinaryTextureRecord;

static inline uint16_t hv_pvg_texture_u16(const uint8_t *p) {
    return (uint16_t)p[0] | (uint16_t)p[1] << 8;
}
static inline uint64_t hv_pvg_texture_u64(const uint8_t *p) {
    return (uint64_t)hv_pvg_texture_u32(p) | (uint64_t)hv_pvg_texture_u32(p+4) << 32;
}

static inline bool hv_pvg_decode_ordinary_texture(const uint8_t *bytes, size_t length,
                                                 HvOrdinaryTextureRecord *out) {
    if (!bytes || !out || length < 36) return false;
    const uint8_t *layout = bytes + 12;
    uint16_t mips = hv_pvg_texture_u16(layout) & 0x3fff;
    size_t table = (size_t)mips * 36;
    if (!mips || table > length - 36 || length - 36 - table < 12) return false;
    const uint8_t *record = bytes + 36 + table;
    uint32_t tag = hv_pvg_texture_u32(record);
    uint32_t size = hv_pvg_texture_u32(record + 4);
    bool v2 = tag == 0x34 || tag == 0x39; /* existing makeTexture dispatch */
    size_t minimum = 12 + (v2 ? 0x27 : 24);
    if (size < minimum || size > length - 36 - table) return false;
    uint64_t backing = hv_pvg_texture_u64(bytes);
    if (backing > UINT64_MAX - 0x3fff) return false; /* page rounding */
    *out = (HvOrdinaryTextureRecord){
        .length=backing, .page=hv_pvg_texture_u32(bytes+8),
        .base=hv_pvg_texture_u64(layout+4), .stride=hv_pvg_texture_u64(layout+12),
        .mips=mips, .slices=hv_pvg_texture_u16(layout+2), .block_height=layout[0x15],
        .layout=layout+24, .descriptor=record+12, .tag=tag,
        .descriptor_size=size, .reference=hv_pvg_texture_u32(record+8), .v2=v2
    };
    return true;
}

/* Positive legacy-table evidence is intentionally narrower than the renderer:
   normal uncompressed 2D, single-slice, single-sample R8/RG8/RGBA8/BGRA8.
   Unknown descriptor tags, other texture kinds/compression and large backing
   ranges remain unsupported as the *first* object. The bounds are policy,
   not claims about all valid Metal textures. */
#define HV_PVG_ORDINARY_BOOTSTRAP_RECORD_LIMIT 4096u
#define HV_PVG_ORDINARY_BOOTSTRAP_BACKING_LIMIT (4u * 1024u * 1024u)
static inline bool hv_pvg_ordinary_texture_bootstrap(const uint8_t *bytes, size_t length,
                                                    uint32_t reference,
                                                    HvOrdinaryTextureRecord *out) {
    HvOrdinaryTextureRecord r;
    if (length > HV_PVG_ORDINARY_BOOTSTRAP_RECORD_LIMIT ||
        !hv_pvg_decode_ordinary_texture(bytes,length,&r)) return false;
    if ((r.tag != 1 && r.tag != 0x14 && r.tag != 0x34) ||
        r.reference != reference || !reference ||
        36u + (size_t)r.mips * 36u + r.descriptor_size != length ||
        !r.page || !r.length || r.length > HV_PVG_ORDINARY_BOOTSTRAP_BACKING_LIMIT ||
        r.slices != 1 || r.block_height > 1 || r.base > r.length) return false;
    const uint8_t *d = r.descriptor;
    uint32_t format, usage, width, height, depth;
    uint16_t mips, samples, array, options;
    if (r.v2) {
        format=hv_pvg_texture_u16(d+1); usage=hv_pvg_texture_u32(d+3);
        width=hv_pvg_texture_u32(d+7); height=hv_pvg_texture_u32(d+11); depth=hv_pvg_texture_u32(d+15);
        mips=hv_pvg_texture_u16(d+19); samples=hv_pvg_texture_u16(d+21);
        array=hv_pvg_texture_u16(d+23); options=hv_pvg_texture_u16(d+25);
        for (unsigned i=0;i<4;i++) if (d[0x23+i] > 5) return false;
    } else {
        format=hv_pvg_texture_u16(d+2); usage=d[1];
        width=hv_pvg_texture_u32(d+4); height=hv_pvg_texture_u32(d+8); depth=hv_pvg_texture_u32(d+12);
        mips=hv_pvg_texture_u16(d+16); samples=hv_pvg_texture_u16(d+18);
        array=hv_pvg_texture_u16(d+20); options=hv_pvg_texture_u16(d+22);
    }
    /* Constants below are the public Metal enums. Keep numeric values here
       so the parser can be tested as plain C, without an Apple framework. */
    uint32_t bpp= format==10 ? 1 : format==30 ? 2 : (format==70 || format==80) ? 4 : 0;
    if (!bpp || (d[0]&0xf)!=2 || (d[0]&~0x4f) || (usage&~0x17u) ||
        (options&~0x3ffu) || (options&0xf)>1 || ((options>>4)&0xf)>3 ||
        ((options>>8)&3)>2 || !width || !height || depth!=1 || samples!=1 || array!=1 || mips!=r.mips) return false;
    uint32_t maxdim=width>height?width:height, levels=1;
    while (maxdim>1) { maxdim>>=1; levels++; }
    if (mips>levels) return false;
    for (uint32_t i=0;i<mips;i++) {
        const uint8_t *m=r.layout + (size_t)i*36;
        uint64_t offset=hv_pvg_texture_u64(m), row=hv_pvg_texture_u64(m+16);
        uint32_t w=hv_pvg_texture_u32(m+24), h=hv_pvg_texture_u32(m+28), z=hv_pvg_texture_u32(m+32);
        uint32_t expected_w=width>>i, expected_h=height>>i;
        if (!expected_w) expected_w=1;
        if (!expected_h) expected_h=1;
        if (w!=expected_w || h!=expected_h || z!=1 || row<(uint64_t)w*bpp || row%bpp) return false;
        /* Subtraction/division keep every storage-range check overflow-free. */
        if (offset>r.length-r.base) return false;
        uint64_t available=r.length-r.base-offset;
        if (!row || row>available/h) return false;
    }
    if (out) *out=r;
    return true;
}

#endif
