#include "HGGuestSnapshotInvalidation.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/file.h>
#include <unistd.h>
#include <zlib.h>

static const char *public_names[]={"resume.hsnap","resume.hsnap.part"};
static const char *private_names[]={"ram-resume.hsnap","ram-resume.hsnap.part"};
static uint64_t get(const unsigned char *p) {
    uint64_t v=0;for(unsigned j=0;j<8;j++)v|=(uint64_t)p[j]<<(8*j);return v;
}
static void put(unsigned char *p,uint64_t v) {
    for(unsigned j=0;j<8;j++)p[j]=(unsigned char)(v>>(8*j));
}
static int no_acl(int fd) {
    errno=0;acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl)return errno==ENOENT;
    acl_entry_t entry;int good=!acl_valid(acl);errno=0;
    int empty=good && acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL;
    acl_free(acl);return empty;
}
static int absent(int directory,const char *name) {
    struct stat st;return fstatat(directory,name,&st,AT_SYMLINK_NOFOLLOW)<0 && errno==ENOENT;
}
static int entry_matches(const unsigned char *p,const struct stat *st) {
    return get(p+8) && S_ISREG(st->st_mode) && st->st_nlink==1 && !st->st_flags &&
        (uint64_t)st->st_dev==get(p) && (uint64_t)st->st_ino==get(p+8) &&
        (uint64_t)st->st_size==get(p+16) && st->st_uid==get(p+24) && st->st_gid==get(p+32) &&
        st->st_mode==get(p+40) && (uint64_t)st->st_mtimespec.tv_sec==get(p+48) &&
        (uint64_t)st->st_mtimespec.tv_nsec==get(p+56);
}
static int receipt_valid(const HGGuestPublicationIntent *i,const unsigned char p[256]) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(i->record,sizeof(i->record),digest);
    if(memcmp(p,"HGSN0001",8) || memcmp(p+8,digest,32) || get(p+248)!=(uint64_t)crc32(0,p,248))return 0;
    for(unsigned j=0;j<2;j++) {
        const unsigned char *e=p+40+j*64;
        if(!get(e+8)) {for(unsigned k=0;k<64;k++)if(e[k])return 0;}
        else if(!get(e) || get(e+16)>INT64_MAX || get(e+24)>UINT32_MAX || get(e+32)>UINT32_MAX ||
                get(e+40)>UINT32_MAX || (get(e+40)&S_IFMT)!=S_IFREG || (get(e+40)&07000) ||
                get(e+56)>=1000000000)return 0;
    }
    if(get(p+48) && get(p+112) && get(p+40)==get(p+104) && get(p+48)==get(p+112))return 0;
    for(unsigned j=168;j<248;j++)if(p[j])return 0;
    return 1;
}
static int receipt_read(const HGGuestPublicationIntent *i,unsigned char p[256],int durable) {
    int fd=openat(i->directory_fd,"snapshot-invalidation",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return -1;
    struct stat st,named;int failed=fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=geteuid() ||
        st.st_nlink!=1 || st.st_flags || (st.st_mode&07777)!=0600 || st.st_size!=256 || !no_acl(fd) ||
        pread(fd,p,256,0)!=256 || !receipt_valid(i,p) ||
        fstatat(i->directory_fd,"snapshot-invalidation",&named,AT_SYMLINK_NOFOLLOW) ||
        st.st_dev!=named.st_dev || st.st_ino!=named.st_ino;
    if(!failed && durable) {
        unsigned char check[256];
        failed=fsync(fd) || fsync(i->directory_fd) || pread(fd,check,256,0)!=256 || memcmp(p,check,256) ||
            fstatat(i->directory_fd,"snapshot-invalidation",&named,AT_SYMLINK_NOFOLLOW) ||
            st.st_dev!=named.st_dev || st.st_ino!=named.st_ino;
    }
    close(fd);return failed?-1:0;
}
int hg_guest_snapshot_invalidation_verify(const HGGuestPublicationIntent *i,int parent,const char **error) {
    if(!error)return -1;
    *error="snapshot-invalidation-receipt";
    HGGuestPublicationPair pair=HG_PUBLICATION_PAIR_UNKNOWN;unsigned char p[256];
    if(!i || hg_guest_publication_intent_pair(i,parent,&pair,error) || receipt_read(i,p,0)) {
        if(!*error)*error="snapshot-invalidation-receipt";
        return -1;
    }
    *error="snapshot-invalidation-incomplete";
    for(unsigned j=0;j<2;j++) {
        const unsigned char *entry=p+40+j*64;struct stat st;
        if(!absent(parent,public_names[j]))return -1;
        if(get(entry+8)) {
            int fd=openat(i->directory_fd,private_names[j],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
            if(fd<0)return -1;
            struct stat named;
            int failed=fstat(fd,&st) || !entry_matches(entry,&st) || !no_acl(fd) ||
                fstatat(i->directory_fd,private_names[j],&named,AT_SYMLINK_NOFOLLOW) || !entry_matches(entry,&named);
            close(fd);if(failed)return -1;
        } else if(!absent(i->directory_fd,private_names[j]))return -1;
    }
    unsigned char final[256];
    *error="snapshot-invalidation-changed";
    if(receipt_read(i,final,0) || memcmp(p,final,256) ||
       !absent(parent,public_names[0]) || !absent(parent,public_names[1]))return -1;
    if(hg_guest_publication_intent_pair(i,parent,&pair,error))return -1;
    *error=NULL;return 0;
}
int hg_guest_snapshot_invalidation_complete(const HGGuestPublicationIntent *i,
    const HGGuestWriteAuthority *a,const char **error) {
    if(!error)return -1;
    *error="snapshot-invalidation-precondition";
    HGGuestPublicationPair pair=HG_PUBLICATION_PAIR_UNKNOWN;
    if(!i || !a || strcmp(a->name,"disk.img") || !hg_guest_write_authority_unchanged(a) ||
       hg_guest_publication_intent_pair(i,a->directory_fd,&pair,error))return -1;
    *error="snapshot-invalidation-precondition";
    if(pair!=HG_PUBLICATION_ORIGINAL_ACTIVE)return -1;
    if(hg_guest_publication_intent_authority_matches(i,a,error))return -1;
    unsigned char p[256],check[256];int fds[2]={-1,-1},from_public[2]={0,0},status=-1;
    *error="snapshot-invalidation-receipt";
    if(receipt_read(i,p,1))return -1;
    *error="snapshot-invalidation-changed";
    // Preflight BOTH positions before moving anything. An inode must occur in
    // exactly one expected location; absent entries must be absent in both.
    for(unsigned j=0;j<2;j++) {
        const unsigned char *entry=p+40+j*64;
        int public_absent=absent(a->directory_fd,public_names[j]);
        int private_absent=absent(i->directory_fd,private_names[j]);
        if(!get(entry+8)) {if(!public_absent || !private_absent)goto done;continue;}
        if(public_absent==private_absent)goto done;
        from_public[j]=!public_absent;
        int directory=from_public[j]?a->directory_fd:i->directory_fd;
        const char *name=from_public[j]?public_names[j]:private_names[j];
        fds[j]=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        struct stat st,named;
        if(fds[j]<0 || fstat(fds[j],&st) || !entry_matches(entry,&st) || !no_acl(fds[j]) ||
           flock(fds[j],LOCK_EX|LOCK_NB) || fstatat(directory,name,&named,AT_SYMLINK_NOFOLLOW) ||
           !entry_matches(entry,&named))goto done;
    }
    for(unsigned j=0;j<2;j++) {
        struct stat st,named;const unsigned char *entry=p+40+j*64;
        if(!hg_guest_write_authority_unchanged(a) || receipt_read(i,check,0) || memcmp(p,check,256))goto done;
        if(fds[j]<0) {
            if(!absent(a->directory_fd,public_names[j]) || !absent(i->directory_fd,private_names[j]))goto done;
            continue;
        }
        int directory=from_public[j]?a->directory_fd:i->directory_fd;
        const char *name=from_public[j]?public_names[j]:private_names[j];
        if(fstat(fds[j],&st) || !entry_matches(entry,&st) ||
           fstatat(directory,name,&named,AT_SYMLINK_NOFOLLOW) || !entry_matches(entry,&named))goto done;
        if(from_public[j]) {
            if(!absent(i->directory_fd,private_names[j]))goto done;
            *error="snapshot-invalidation-rename";
            if(renameatx_np(a->directory_fd,public_names[j],i->directory_fd,private_names[j],RENAME_EXCL))goto done;
        } else if(!absent(a->directory_fd,public_names[j]))goto done;
        *error="snapshot-invalidation-changed";
    }
    // Also sync on an already-complete retry: a prior process may have exited
    // after rename but before either directory's durability barrier.
    *error="snapshot-invalidation-sync";
    if(fsync(a->directory_fd) || fsync(i->directory_fd))goto done;
    *error="snapshot-invalidation-changed";
    if(!hg_guest_write_authority_unchanged(a))goto done;
    status=hg_guest_snapshot_invalidation_verify(i,a->directory_fd,error);
 done:
    for(unsigned j=0;j<2;j++)if(fds[j]>=0)close(fds[j]);
    return status;
}
int hg_guest_snapshot_invalidate(const HGGuestPublicationIntent *i,
    const HGGuestWriteAuthority *a,const char **error) {
    if(!error)return -1;
    *error="snapshot-invalidation-precondition";
    HGGuestPublicationPair pair=HG_PUBLICATION_PAIR_UNKNOWN;
    if(!i || !a || strcmp(a->name,"disk.img") || !hg_guest_write_authority_unchanged(a) ||
       hg_guest_publication_intent_pair(i,a->directory_fd,&pair,error))return -1;
    *error="snapshot-invalidation-precondition";
    if(pair!=HG_PUBLICATION_ORIGINAL_ACTIVE)return -1;
    if(hg_guest_publication_intent_authority_matches(i,a,error))return -1;
    unsigned char p[256]={0};int fds[2]={-1,-1},status=-1;
    memcpy(p,"HGSN0001",8);CC_SHA256(i->record,sizeof(i->record),p+8);
    *error="snapshot-invalidation-input";
    for(unsigned j=0;j<2;j++) {
        if(!absent(i->directory_fd,private_names[j]))goto done;
        fds[j]=openat(a->directory_fd,public_names[j],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        if(fds[j]<0) {if(errno==ENOENT)continue;goto done;}
        struct stat st,named;
        if(fstat(fds[j],&st) || !S_ISREG(st.st_mode) || st.st_nlink!=1 || st.st_flags ||
           st.st_uid!=a->principal_uid || st.st_dev!=a->source->identity.st_dev || (st.st_mode&07000) || !no_acl(fds[j]) ||
           flock(fds[j],LOCK_EX|LOCK_NB) ||
           fstatat(a->directory_fd,public_names[j],&named,AT_SYMLINK_NOFOLLOW) ||
           st.st_dev!=named.st_dev || st.st_ino!=named.st_ino)goto done;
        unsigned char *e=p+40+j*64;
        put(e,st.st_dev);put(e+8,st.st_ino);put(e+16,st.st_size);put(e+24,st.st_uid);
        put(e+32,st.st_gid);put(e+40,st.st_mode);put(e+48,st.st_mtimespec.tv_sec);put(e+56,st.st_mtimespec.tv_nsec);
    }
    put(p+248,(uint64_t)crc32(0,p,248));
    if(!receipt_valid(i,p) || !hg_guest_write_authority_unchanged(a))goto done;
    *error="snapshot-invalidation-create";
    int fd=openat(i->directory_fd,"snapshot-invalidation",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)goto done;
    unsigned char check[256];
    int failed=fchmod(fd,0600) || pwrite(fd,p,256,0)!=256 || fsync(fd) || fsync(i->directory_fd) ||
        pread(fd,check,256,0)!=256 || memcmp(p,check,256);
    close(fd);*error="snapshot-invalidation-sync";if(failed)goto done;
    if(receipt_read(i,check,0) || memcmp(p,check,256))goto done;
    // Release the inventory leases before complete reacquires all of them.
    for(unsigned j=0;j<2;j++)if(fds[j]>=0){close(fds[j]);fds[j]=-1;}
    status=hg_guest_snapshot_invalidation_complete(i,a,error);
 done:
    for(unsigned j=0;j<2;j++)if(fds[j]>=0)close(fds[j]);
    return status;
}
