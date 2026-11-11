/* APFS layout: Apple File System Reference (2020-06-22), objects, containers,
 * object maps and volume superblocks. This profile is metadata inspection only. */
#include "HGGuestAPFS.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint16_t u16(const unsigned char *p) { return p[0] | (uint16_t)p[1] << 8; }
static uint32_t u32(const unsigned char *p) { return u16(p) | (uint32_t)u16(p+2) << 16; }
static uint64_t u64(const unsigned char *p) { return u32(p) | (uint64_t)u32(p+4) << 32; }
static int nonzero(const unsigned char *p, size_t n) {
    while (n--) if (*p++) return 1;
    return 0;
}
static int checksum(const unsigned char *p, uint32_t size) {
    uint64_t a=0,b=0,m=UINT32_MAX;
    for (uint32_t i=8;i<size;i+=4) { a=(a+u32(p+i))%m; b=(b+a)%m; }
    uint32_t lo=(uint32_t)(m-(a+b)%m), hi=(uint32_t)(m-(a+lo)%m);
    return u32(p)==lo && u32(p+4)==hi;
}
typedef struct {
    const HGGuestDisk *disk;
    uint64_t base, bytes, count, xid;
    uint32_t size;
    const char **error;
} Reader;
static int bytes(Reader *r, uint64_t offset, unsigned char *p, uint32_t n) {
    if (offset>r->bytes || n>r->bytes-offset) { *r->error="apfs-block-range"; return -1; }
    size_t done=0;
    while (done<n) {
        ssize_t got=pread(r->disk->fd,p+done,n-done,(off_t)(r->base+offset+done));
        if (got<0 && errno==EINTR) continue;
        if (got<=0) { *r->error="apfs-read"; return -1; }
        done+=(size_t)got;
    }
    return 0;
}
static int block(Reader *r, uint64_t index, unsigned char *p) {
    if (index>=r->count || index>UINT64_MAX/r->size) { *r->error="apfs-block-range"; return -1; }
    if (bytes(r,index*r->size,p,r->size)) return -1;
    if (!checksum(p,r->size)) { *r->error="apfs-object-checksum"; return -1; }
    return 0;
}
static int omap_lookup(Reader *r, uint64_t tree, uint64_t oid, uint64_t *physical, uint64_t *mapped_xid) {
    unsigned char *p=malloc(r->size);
    if (!p) { *r->error="apfs-allocation"; return -1; }
    uint64_t visited[16];
    unsigned int previous=16;
    int result=-1;
    *r->error="unsupported-apfs-object-map";
    for (unsigned int depth=0;depth<16;depth++) {
        for (unsigned int i=0;i<depth;i++) if (visited[i]==tree) goto done;
        visited[depth]=tree;
        if (block(r,tree,p)) goto done;
        uint16_t type=(uint16_t)u32(p+24), flags=u16(p+32), level=u16(p+34);
        uint32_t count=u32(p+36), off=u16(p+40), length=u16(p+42);
        uint32_t keybase=56+off+length, end=r->size-((flags&1)?40:0);
        if (type!=(depth?3:2) || u32(p+28)!=11 || u64(p+16)>r->xid ||
            (flags&~7) || !(flags&4) || !!(flags&1)!=!depth || !!(flags&2)!=!level ||
            level>=previous || !count || count>r->size/20 || count*4>length ||
            keybase>end || off>r->size-56) goto done;
        previous=level;
        int best=-1;
        uint64_t last_oid=0,last_xid=0;
        uint32_t largest_key_end=keybase, first_value=end;
        for (uint32_t i=0;i<count;i++) {
            const unsigned char *entry=p+56+off+i*4;
            uint32_t k=keybase+u16(entry), vo=u16(entry+2), value_size=level?8:16;
            if (k>end || 16>end-k || vo==UINT16_MAX || vo>end-keybase || vo<value_size) goto done;
            uint32_t v=end-vo;
            // Key/value regions must not overlap, even for malformed free-space metadata.
            if (v<keybase || k+16>v) goto done;
            if (k+16>largest_key_end) largest_key_end=k+16;
            if (v<first_value) first_value=v;
            uint64_t koid=u64(p+k), kxid=u64(p+k+8);
            if (i && (koid<last_oid || (koid==last_oid && kxid<=last_xid))) goto done;
            last_oid=koid; last_xid=kxid;
            if (koid<oid || (koid==oid && kxid<=r->xid)) best=(int)i;
        }
        if (largest_key_end>first_value) goto done;
        if (best<0) goto done;
        const unsigned char *entry=p+56+off+(uint32_t)best*4;
        const unsigned char *key=p+keybase+u16(entry), *value=p+end-u16(entry+2);
        if (!level) {
            // Deleted, encrypted, headerless or unknown mappings are unsupported.
            if (u64(key)!=oid || (u32(value)&~2u) || u32(value+4)!=r->size) goto done;
            *physical=u64(value+8); *mapped_xid=u64(key+8); result=0; goto done;
        }
        tree=u64(value);
    }
done:
    free(p);
    return result;
}

int hg_guest_apfs_inspect(const HGGuestDisk *disk, HGGuestAPFS *apfs, const char **error) {
    if (!disk || !apfs || !error) return -1;
    memset(apfs,0,sizeof(*apfs)); *error="unsupported-apfs-container";
    if (!hg_guest_disk_unchanged(disk) || disk->last_apfs_lba<disk->first_apfs_lba ||
        disk->first_apfs_lba>UINT64_MAX/512 || disk->last_apfs_lba==UINT64_MAX ||
        disk->last_apfs_lba+1>UINT64_MAX/512) return -1;
    Reader r={.disk=disk,.base=disk->first_apfs_lba*512,
              .bytes=(disk->last_apfs_lba-disk->first_apfs_lba+1)*512,.error=error};
    if (r.base>(uint64_t)disk->identity.st_size || r.bytes>(uint64_t)disk->identity.st_size-r.base) return -1;
    unsigned char initial[4096];
    if (bytes(&r,0,initial,sizeof(initial))) return -1;
    r.size=u32(initial+36); r.count=u64(initial+40);
    if (memcmp(initial+32,"NXSB",4) || r.size<4096 || r.size>65536 ||
        (r.size&(r.size-1)) || !r.count || r.count>r.bytes/r.size) return -1;
    unsigned char *nx=malloc(r.size), *p=malloc(r.size);
    if (!nx || !p) { free(nx);free(p);*error="apfs-allocation";return -1; }
    int result=-1;
    if (block(&r,0,nx)) goto done;
    if ((u32(nx+24)&0xffff)!=1 || u64(nx+64)!=2 || !nonzero(nx+72,16)) goto done;
    uint32_t descriptors=u32(nx+104);
    uint64_t descriptor_base=u64(nx+112);
    if (!descriptors || descriptors>4096 || descriptor_base>=r.count || descriptors>r.count-descriptor_base) goto done;
    for (uint32_t i=0;i<descriptors;i++) {
        // Descriptor slots also contain checkpoint maps; only NX objects need
        // to be interpreted here. Bounds are checked before any read.
        if (bytes(&r,(descriptor_base+i)*r.size,p,r.size)) goto done;
        if (memcmp(p+32,"NXSB",4)) continue;
        if (!checksum(p,r.size)) { *error="apfs-object-checksum";goto done; }
        if ((u32(p+24)&0xffff)!=1 || u32(p+36)!=r.size || u64(p+40)!=r.count ||
            memcmp(p+72,nx+72,16) || u64(p+64)!=2) goto done;
        if (u64(p+16)>u64(nx+16)) memcpy(nx,p,r.size);
        else if (u64(p+16)==u64(nx+16) && memcmp(p+160,nx+160,24+100*8)) {
            *error="ambiguous-apfs-checkpoint";goto done;
        }
    }
    r.xid=u64(nx+16);
    uint32_t slots=u32(nx+180);
    if (!slots || slots>100 || 184+slots*8>r.size || !r.xid) goto done;
    if (block(&r,u64(nx+160),p)) goto done;
    if ((u32(p+24)&0xffff)!=11 || u64(p+16)>r.xid) goto done;
    uint64_t tree=u64(p+48);
    for (uint32_t i=0;i<slots;i++) {
        uint64_t oid=u64(nx+184+i*8), address=0,xid=0;
        if (!oid) continue;
        for (uint32_t j=0;j<apfs->volume_count;j++) if (apfs->volumes[j].oid==oid) goto done;
        if (omap_lookup(&r,tree,oid,&address,&xid) || block(&r,address,p)) goto done;
        if ((u32(p+24)&0xffff)!=13 || memcmp(p+32,"APSB",4) ||
            u64(p+8)!=oid || u64(p+16)!=xid || !nonzero(p+240,16)) goto done;
        HGGuestAPFSVolume *v=&apfs->volumes[apfs->volume_count++];
        v->oid=oid;v->xid=xid;v->physical_block=address;v->role=u16(p+964);v->flags=u64(p+264);
        memcpy(v->uuid,p+240,16);memcpy(v->group_uuid,p+1008,16);
        for (uint32_t j=0;j+1<apfs->volume_count;j++)
            if (!memcmp(apfs->volumes[j].uuid,v->uuid,16)) goto done;
    }
    if (!apfs->volume_count || !hg_guest_disk_unchanged(disk)) goto done;
    apfs->block_size=r.size;apfs->block_count=r.count;apfs->checkpoint_xid=r.xid;
    *error=NULL;result=0;
done:
    free(nx);free(p);
    if (result) memset(apfs,0,sizeof(*apfs));
    return result;
}
