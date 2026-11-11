/* Authored normal texture records; CPU-only layout/parser assertions. */
#include "pvg_texture_record.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
static void check(bool ok,const char *name) { checks++; if(!ok){fprintf(stderr,"FAIL %s\n",name);exit(1);} }
static void u16(uint8_t*p,uint16_t n){p[0]=n;p[1]=n>>8;}
static void u32(uint8_t*p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(i*8));}
static void u64(uint8_t*p,uint64_t n){u32(p,(uint32_t)n);u32(p+4,(uint32_t)(n>>32));}
/* Only fields consumed by the user-owned source are authored. Reserved bytes
   stay zero, and no interpretation of them is inferred. */
static size_t ordinary(uint8_t *b,bool v2,uint32_t format,uint32_t width,uint32_t height,uint16_t mips) {
    memset(b,0,4096); u64(b,16384);u32(b+8,0x41);
    u16(b+12,mips);u16(b+14,1);u64(b+24,16384); b[12+0x15]=1;
    uint64_t off=0;
    for(uint16_t i=0;i<mips;i++) {
        uint32_t w=width>>i,h=height>>i;if(!w)w=1;if(!h)h=1;
        uint8_t*m=b+36+i*36;u64(m,off);u64(m+16,256);
        u32(m+24,w);u32(m+28,h);u32(m+32,1);off+=256*h;
    }
    uint8_t*r=b+36+mips*36;uint32_t ds=v2?52:36;
    u32(r,v2?0x34:0x14);u32(r+4,ds);u32(r+8,1);uint8_t*d=r+12;d[0]=0x42;
    if(v2){u16(d+1,format);u32(d+3,5);u32(d+7,width);u32(d+11,height);u32(d+15,1);u16(d+19,mips);u16(d+21,1);u16(d+23,1);u16(d+25,0x10);d[35]=2;d[36]=3;d[37]=4;d[38]=5;}
    else {d[1]=5;u16(d+2,format);u32(d+4,width);u32(d+8,height);u32(d+12,1);u16(d+16,mips);u16(d+18,1);u16(d+20,1);u16(d+22,0x10);}
    return 36+mips*36+ds;
}
int main(void) {
    uint8_t b[4096],copy[4096];HvOrdinaryTextureRecord r;
    const uint32_t formats[]={10,30,70,80};
    for(unsigned version=0;version<2;version++)for(unsigned f=0;f<4;f++) {
        size_t n=ordinary(b,version,formats[f],4,4,1);
        check(hv_pvg_decode_ordinary_texture(b,n,&r),"bounded v1/v2 normal decode");
        check(hv_pvg_ordinary_texture_bootstrap(b,n,1,&r),"ordinary supported formats recognized");
        check(r.page==0x41 && r.length==16384 && r.mips==1 && r.slices==1 && r.layout==b+36 && r.descriptor==b+84,"decoded layout matches authored fields");
        for(size_t cut=0;cut<n;cut++)check(!hv_pvg_ordinary_texture_bootstrap(b,cut,1,NULL),"truncated record never establishes table");
    }
    size_t n=ordinary(b,true,70,8,4,4);
    check(hv_pvg_ordinary_texture_bootstrap(b,n,1,&r),"complete multi-mip layout accepted");
    n=ordinary(b,true,80,64,4,1);
    check(hv_pvg_ordinary_texture_bootstrap(b,n,1,&r),"64 by 4 supported normal layout");
    n=ordinary(b,true,70,4,4,1);memcpy(copy,b,n);
#define REJECT(change,label) do {memcpy(b,copy,n);change;check(!hv_pvg_ordinary_texture_bootstrap(b,n,1,NULL),label);}while(0)
    REJECT(u32(b+80,2),"other reference cannot prove ref1");
    REJECT(u32(b+72,0x39),"unestablished ordinary tag stays unsupported for bootstrap");
    REJECT(u32(b+76,51),"trailing bytes outside declared descriptor rejected for bootstrap");
    REJECT(u32(b+76,53),"descriptor cannot extend beyond record");
    REJECT(u16(b+12,2),"layout table must fit before descriptor");
    REJECT(u64(b,UINT64_MAX),"backing rounding overflow rejected");
    REJECT(u64(b,HV_PVG_ORDINARY_BOOTSTRAP_BACKING_LIMIT+1ull),"large backing outside bounded bootstrap policy");
    REJECT(u32(b+8,0),"missing backing page rejected");
    REJECT(u64(b+36,UINT64_MAX),"offset cannot wrap storage bound");
    REJECT(u64(b+52,UINT64_MAX),"row span cannot wrap storage bound");
    REJECT(u64(b+52,4),"row must cover pixel width");
    REJECT(u32(b+64,5),"mip geometry must match descriptor");
    REJECT(u32(b+68,2),"unsupported depth stays unsupported");
    REJECT(b[33]=4,"compressed block layout stays unsupported");
    REJECT(b[84]=0x44,"multisample type stays unsupported");
    REJECT(b[84]=0x52,"framebuffer-only storage stays unsupported");
    REJECT(u16(b+85,115),"unestablished pixel size stays unsupported");
    REJECT(u16(b+105,4),"multisample count stays unsupported");
    REJECT(u16(b+107,2),"array texture stays unsupported");
    REJECT(u16(b+109,0x300),"unknown hazard option stays unsupported");
    REJECT(b[119]=6,"out-of-range swizzle stays unsupported");
#undef REJECT
    memcpy(b,copy,n);HvOrdinaryTextureRecord sentinel={.reference=777};
    check(!hv_pvg_decode_ordinary_texture(b,12,&sentinel) && sentinel.reference==777,"failed decode leaves output untouched");
    check(!hv_pvg_decode_ordinary_texture(NULL,n,&r) && !hv_pvg_decode_ordinary_texture(b,n,NULL),"null arguments rejected");
    puts("Authored ordinary texture parser tests: CPU only");
    printf("%u checks passed\n",checks);
    return 0;
}
