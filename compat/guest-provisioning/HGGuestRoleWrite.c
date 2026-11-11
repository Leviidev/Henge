#include "HGGuestRoleWrite.h"
#include "HGGuestRoles.h"
#include "HGGuestMedia.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint16_t u16(const unsigned char *p) { return p[0]|(uint16_t)p[1]<<8; }
static uint32_t u32(const unsigned char *p) { return u16(p)|(uint32_t)u16(p+2)<<16; }
static uint64_t u64(const unsigned char *p) { return u32(p)|(uint64_t)u32(p+4)<<32; }
static void put32(unsigned char *p,uint32_t v) {
    for (unsigned i=0;i<4;i++) p[i]=(unsigned char)(v>>(i*8));
}
static void put64(unsigned char *p,uint64_t v) {
    for (unsigned i=0;i<8;i++) p[i]=(unsigned char)(v>>(i*8));
}
static void checksum(unsigned char *p,uint32_t n) {
    uint64_t a=0,b=0,m=UINT32_MAX;
    for (uint32_t i=8;i<n;i+=4) { a=(a+u32(p+i))%m;b=(b+a)%m; }
    uint32_t lo=(uint32_t)(m-(a+b)%m);
    put32(p,lo);put32(p+4,(uint32_t)(m-(a+lo)%m));
}
static int io(int fd,void *data,size_t n,uint64_t offset,int writing) {
    unsigned char *p=data;
    while (n) {
        ssize_t r=writing?pwrite(fd,p,n,(off_t)offset):pread(fd,p,n,(off_t)offset);
        if (r<0 && errno==EINTR) continue;
        if (r<=0) return -1;
        n-=(size_t)r;p+=r;offset+=(uint64_t)r;
    }
    return 0;
}
static int same_inode(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static int owned(HGGuestClone *c,HGGuestDisk *view) {
    struct stat named,parent;
    if (!c || !c->created || !c->source || c->disk.fd<0 || c->directory_fd<0 ||
        fstat(c->directory_fd,&parent) || !S_ISDIR(parent.st_mode) ||
        parent.st_uid!=geteuid() || (parent.st_mode&0077) ||
        fstatat(c->directory_fd,c->name,&named,AT_SYMLINK_NOFOLLOW)) return 0;
    *view=c->disk;
    if (fstat(view->fd,&view->identity) || !same_inode(&named,&view->identity) ||
        !same_inode(&named,&c->created_identity) || !S_ISREG(named.st_mode) ||
        named.st_nlink!=1 || named.st_uid!=geteuid() || (named.st_mode&0777)!=0600 ||
        named.st_size!=c->source->identity.st_size ||
        same_inode(&named,&c->source->identity)) return 0;
    return hg_guest_disk_unchanged(c->source);
}
static int empty_media(const HGGuestDisk *disk,const char **error) {
    char *json=NULL;
    int result=hg_guest_media_copy(disk,&json,error);
    int empty=!result && json && !strcmp(json,"[]");
    free(json);return empty;
}

int hg_guest_roles_write(HGGuestClone *c,int restore,
                         HGGuestRoleWriteReport *report,const char **error) {
    if (!report || !error) return -1;
    *error="role-write-identity";
    if (report->journal_name[0] || report->edited_blocks || report->journal_durable || report->image_durable ||
        !c || c->mutation_failed || (restore!=0 && restore!=1)) return -1;
    HGGuestDisk view;HGGuestAPFSCatalog *a=NULL,*b=NULL;
    HGGuestRolePlan *plan=NULL;unsigned char *blocks=NULL,*check=NULL;
    int writer=-1,journal=-1,result=-1;
    if (!owned(c,&view)) return -1;
    if (!empty_media(&view,error)) { *error="role-write-media-busy";return -1; }
    if (hg_guest_apfs_copy_catalog(c->source,&a,error) ||
        hg_guest_apfs_copy_catalog(&view,&b,error) ||
        hg_guest_roles_plan(a,b,restore,&plan,error)) goto done;
    uint32_t size=b->block_size;
    /* Two full blocks per edit; cap both journal and memory to 32 MiB. */
    if (64+(uint64_t)plan->count*(8+(uint64_t)size*2)>32u*1024u*1024u) {
        *error="role-journal-budget";goto done;
    }
    blocks=malloc((size_t)size*2*(plan->count?plan->count:1));check=malloc(size);
    if (!blocks || !check) { *error="role-write-allocation";goto done; }
    uint64_t base=view.first_apfs_lba*512;
    uint64_t bytes=(view.last_apfs_lba-view.first_apfs_lba+1)*512;
    for (uint32_t i=0;i<plan->count;i++) {
        const HGGuestAPFSVolume *v=&plan->edits[i].expected;
        if (bytes<size || v->physical_block>(bytes-size)/size) {
            *error="role-write-block-range";goto done;
        }
        unsigned char *old=blocks+(size_t)i*size*2,*next=old+size;
        if (io(view.fd,old,size,base+v->physical_block*size,0)) {
            *error="role-write-read";goto done;
        }
        memcpy(check,old,size);checksum(check,size);
        if (memcmp(check,old,8) || memcmp(old+32,"APSB",4) ||
            u32(old+24)!=13 || u64(old+8)!=v->oid || u64(old+16)!=v->xid ||
            u64(old+264)!=v->flags || memcmp(old+240,v->uuid,16) ||
            memcmp(old+1008,v->group_uuid,16) || u16(old+964)!=v->role) {
            *error="role-write-record-changed";goto done;
        }
        memcpy(next,old,size);
        next[964]=(unsigned char)plan->edits[i].target_role;
        next[965]=(unsigned char)(plan->edits[i].target_role>>8);checksum(next,size);
    }
    if (!hg_guest_disk_unchanged(&view) || !hg_guest_disk_unchanged(c->source) ||
        !empty_media(&view,error)) { *error="role-write-preflight-changed";goto done; }
    if (!plan->count) {
        if (fsync(view.fd) || !owned(c,&view)) { *error="role-write-final-identity";goto done; }
        c->disk.identity=view.identity;
        report->image_durable=1;result=0;*error=NULL;goto done;
    }
    writer=openat(c->directory_fd,c->name,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    struct stat writable;
    if (writer<0 || fstat(writer,&writable) || !same_inode(&writable,&view.identity) ||
        !hg_guest_disk_unchanged(&view)) { *error="role-write-open";goto done; }
    uint64_t nonce;arc4random_buf(&nonce,sizeof(nonce));
    snprintf(report->journal_name,sizeof(report->journal_name),"%s.roles-%016llx",
             c->name,(unsigned long long)nonce);
    journal=openat(c->directory_fd,report->journal_name,
                   O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (journal<0) { report->journal_name[0]=0;*error="role-journal-create";goto done; }
    /* From this point a failure means discard-only, even if no image write ran. */
    c->mutation_failed=1;
    if (fstat(journal,&report->journal_identity) ||
        fchmod(journal,0600)) { *error="role-journal-identity";goto done; }
    unsigned char header[64]={0};memcpy(header,"HGRJ0001",8);
    put64(header+8,(uint64_t)view.identity.st_dev);
    put64(header+16,(uint64_t)view.identity.st_ino);
    put64(header+24,(uint64_t)view.identity.st_size);
    put64(header+32,base);put32(header+40,size);put32(header+44,plan->count);
    put32(header+48,(uint32_t)restore);
    if (io(journal,header,sizeof(header),0,1)) { *error="role-journal-write";goto done; }
    uint64_t position=sizeof(header);
    for (uint32_t i=0;i<plan->count;i++) {
        unsigned char offset[8];put64(offset,base+plan->edits[i].expected.physical_block*size);
        if (io(journal,offset,8,position,1) ||
            io(journal,blocks+(size_t)i*size*2,size*2,position+8,1)) {
            *error="role-journal-write";goto done;
        }
        position+=8+(uint64_t)size*2;
    }
    if (fsync(journal) || fsync(c->directory_fd)) { *error="role-journal-sync";goto done; }
    /* Read back the complete persisted recovery record before touching the
     * image, including every offset and both full block versions. */
    if (io(journal,check,sizeof(header),0,0) || memcmp(check,header,sizeof(header))) {
        *error="role-journal-readback";goto done;
    }
    position=sizeof(header);
    for (uint32_t i=0;i<plan->count;i++) {
        uint64_t offset=base+plan->edits[i].expected.physical_block*size;
        if (io(journal,check,8,position,0) || u64(check)!=offset ||
            io(journal,check,size,position+8,0) ||
            memcmp(check,blocks+(size_t)i*size*2,size) ||
            io(journal,check,size,position+8+size,0) ||
            memcmp(check,blocks+((size_t)i*2+1)*size,size)) {
            *error="role-journal-readback";goto done;
        }
        position+=8+(uint64_t)size*2;
    }
    report->journal_durable=1;
    if (!hg_guest_disk_unchanged(&view) || !owned(c,&view) ||
        !empty_media(&view,error) || !hg_guest_disk_unchanged(&view)) {
        *error="role-write-preflight-changed";goto done;
    }
    for (uint32_t i=0;i<plan->count;i++) {
        uint64_t offset=base+plan->edits[i].expected.physical_block*size;
        unsigned char *old=blocks+(size_t)i*size*2;
        if (!hg_guest_disk_unchanged(c->source) || io(writer,check,size,offset,0) ||
            memcmp(check,old,size)) { *error="role-write-record-changed";goto done; }
        if (io(writer,old+size,size,offset,1)) { *error="role-write-failed";goto done; }
        report->edited_blocks++;
    }
    if (fsync(writer)) { *error="role-write-sync";goto done; }
    for (uint32_t i=0;i<plan->count;i++) {
        uint64_t offset=base+plan->edits[i].expected.physical_block*size;
        if (io(writer,check,size,offset,0) ||
            memcmp(check,blocks+((size_t)i*2+1)*size,size)) {
            *error="role-write-readback";goto done;
        }
    }
    if (!owned(c,&view)) { *error="role-write-final-identity";goto done; }
    c->disk.identity=view.identity;c->mutation_failed=0;
    report->image_durable=1;result=0;*error=NULL;
done:
    if (journal>=0) close(journal);
    if (writer>=0) close(writer);
    free(blocks);free(check);free(plan);free(a);free(b);return result;
}
