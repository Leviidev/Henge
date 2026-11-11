#include "HGGuestPublicationRollback.h"
#include "HGGuestSnapshotInvalidation.h"
#include "HGGuestMedia.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <unistd.h>

static uint64_t get(const unsigned char *p) {
    uint64_t v=0;for(unsigned j=0;j<8;j++)v|=(uint64_t)p[j]<<(8*j);return v;
}
static int no_acl(int fd) {
    errno=0;acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl)return errno==ENOENT;
    acl_entry_t entry;int good=!acl_valid(acl);errno=0;
    int empty=good && acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL;
    acl_free(acl);return empty;
}
static int empty(const HGGuestDisk *disk,const char **error) {
    char *media=NULL;int status=hg_guest_media_copy(disk,&media,error);
    int result=!status && media && !strcmp(media,"[]");free(media);return result;
}
static int metadata(const struct stat *st,const unsigned char *p,uint64_t ino,int original) {
    return S_ISREG(st->st_mode) && st->st_nlink==1 && !st->st_flags &&
        (uint64_t)st->st_dev==get(p+40) && (uint64_t)st->st_ino==ino && (uint64_t)st->st_size==get(p+56) &&
        st->st_uid==get(p+88) && st->st_gid==get(p+96) && st->st_mode==get(p+104) &&
        (!original || ((uint64_t)st->st_mtimespec.tv_sec==get(p+112) &&
                      (uint64_t)st->st_mtimespec.tv_nsec==get(p+120)));
}
static int preflight(const HGGuestPublicationIntent *i,const HGGuestWriteAuthority *a,
    const HGGuestDisk *private,HGGuestPublicationPair expected,const char **error) {
    *error="publication-rollback-precondition";
    if(!hg_guest_write_authority_unchanged(a) || !hg_guest_disk_unchanged(private) || !no_acl(private->fd))return -1;
    HGGuestPublicationPair pair=HG_PUBLICATION_PAIR_UNKNOWN;
    if(hg_guest_publication_intent_pair(i,a->directory_fd,&pair,error))return -1;
    *error="publication-rollback-metadata";
    const unsigned char *p=i->record;
    if(pair!=expected || (pair!=HG_PUBLICATION_ORIGINAL_ACTIVE && pair!=HG_PUBLICATION_COPY_ACTIVE) ||
       a->principal_uid!=get(p+88) || strcmp(a->name,(const char *)p+160) ||
       !metadata(&a->source->identity,p,get(p+(pair==HG_PUBLICATION_ORIGINAL_ACTIVE?48:72)),pair==HG_PUBLICATION_ORIGINAL_ACTIVE) ||
       !metadata(&private->identity,p,get(p+(pair==HG_PUBLICATION_ORIGINAL_ACTIVE?72:48)),pair==HG_PUBLICATION_COPY_ACTIVE))return -1;
    return hg_guest_snapshot_invalidation_verify(i,a->directory_fd,error);
}
static int namespace_unchanged(const HGGuestWriteAuthority *a) {
    struct stat parent;
    return !fstat(a->directory_fd,&parent) && S_ISDIR(parent.st_mode) &&
        parent.st_dev==a->directory_identity.st_dev && parent.st_ino==a->directory_identity.st_ino &&
        parent.st_uid==a->principal_uid && (parent.st_mode&0300)==0300 && !(parent.st_mode&0022) &&
        !parent.st_flags && no_acl(a->directory_fd);
}
static int after_matches(const HGGuestDisk *disk,const struct stat *before) {
    struct stat after;
    return !fstat(disk->fd,&after) && after.st_dev==before->st_dev && after.st_ino==before->st_ino &&
        after.st_size==before->st_size && after.st_uid==before->st_uid && after.st_gid==before->st_gid &&
        after.st_mode==before->st_mode && after.st_nlink==1 && !after.st_flags &&
        after.st_mtimespec.tv_sec==before->st_mtimespec.tv_sec &&
        after.st_mtimespec.tv_nsec==before->st_mtimespec.tv_nsec && no_acl(disk->fd);
}
int hg_guest_publication_rollback(const HGGuestPublicationIntent *i,
    const HGGuestWriteAuthority *a,const HGGuestDisk *private,int executable,const HGGuestPeer *peer,
    HGGuestRollbackReport *r,const char **error) {
    if(!error || !r)return -1;
    memset(r,0,sizeof(*r));*error="publication-rollback-caller";
    if(!i || !a || !a->source || !private || !peer || !peer->verified || peer->uid!=a->principal_uid ||
       hg_guest_peer_unchanged(executable,peer,error))return -1;
    HGGuestPublicationPair pair=HG_PUBLICATION_PAIR_UNKNOWN;
    if(hg_guest_publication_intent_pair(i,a->directory_fd,&pair,error))return -1;
    if(preflight(i,a,private,pair,error))return -1;
    if(!empty(a->source,error) || !empty(private,error)) {
        *error="publication-rollback-media";return -1;
    }
    // Media discovery is an external observation. Recheck peer, both retained
    // leases, metadata, record/pair and snapshot namespace after it completes.
    if(hg_guest_peer_unchanged(executable,peer,error) || preflight(i,a,private,pair,error))return -1;
    struct stat active_before=a->source->identity,private_before=private->identity;
    if(pair==HG_PUBLICATION_COPY_ACTIVE) {
        r->exchange_attempted=1;*error="publication-rollback-exchange";
        if(renameatx_np(a->directory_fd,a->name,i->directory_fd,(const char *)i->record+416,RENAME_SWAP)) {
            const char *ignored=NULL;
            (void)hg_guest_publication_intent_pair(i,a->directory_fd,&r->observed_pair,&ignored);
            return -1;
        }
    }
    *error="publication-rollback-sync";
    int failed=fsync(a->directory_fd) || fsync(i->directory_fd);
    const char *position_error=NULL;
    if(hg_guest_publication_intent_pair(i,a->directory_fd,&r->observed_pair,&position_error) ||
       r->observed_pair!=HG_PUBLICATION_ORIGINAL_ACTIVE) {
        *error=position_error?position_error:"publication-rollback-position";return -1;
    }
    if(failed)return -1;
    *error="publication-rollback-changed";
    if(!namespace_unchanged(a) || !after_matches(a->source,&active_before) || !after_matches(private,&private_before) ||
       hg_guest_snapshot_invalidation_verify(i,a->directory_fd,error) ||
       hg_guest_peer_unchanged(executable,peer,error))return -1;
    r->durability_confirmed=1;*error=NULL;return 0;
}
