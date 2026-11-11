#include "HGGuestPublicationMetadata.h"
#include "HGGuestMedia.h"
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <unistd.h>

static int inode(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static int content_metadata(const struct stat *a,const struct stat *b) {
    return inode(a,b) && S_ISREG(b->st_mode) && b->st_nlink==1 && !b->st_flags &&
        a->st_size==b->st_size && a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec &&
        a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec;
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
static int position(const HGGuestPublicationIntent *i,const HGGuestClone *c,
    const HGGuestWriteAuthority *a,const char **error) {
    HGGuestPublicationPair pair=HG_PUBLICATION_PAIR_UNKNOWN;
    struct stat private,parent,named;
    const char *pair_error=NULL;
    int valid=!hg_guest_publication_intent_pair(i,a->directory_fd,&pair,&pair_error) &&
        pair==HG_PUBLICATION_ORIGINAL_ACTIVE && !fstat(c->directory_fd,&private) &&
        !fstat(i->directory_fd,&parent) && inode(&private,&parent) &&
        !fstatat(c->directory_fd,c->name,&named,AT_SYMLINK_NOFOLLOW) &&
        inode(&named,&c->disk.identity) && inode(&named,&c->created_identity) && named.st_nlink==1;
    if(!valid)*error=pair_error?pair_error:"publication-metadata-position";
    return valid;
}
int hg_guest_publication_metadata_set(const HGGuestPublicationIntent *i,
    HGGuestClone *c,const HGGuestWriteAuthority *a,int restore,const char **error) {
    if(!error)return -1;
    *error="publication-metadata-precondition";
    if(!i || !c || !a || (restore!=0 && restore!=1) || !a->source || c->source!=a->source ||
       !c->created || c->mutation_failed || !hg_guest_write_authority_unchanged(a) ||
       !hg_guest_disk_unchanged(&c->disk) || !no_acl(c->disk.fd) ||
       !position(i,c,a,error))return -1;
    const struct stat *original=&c->created_identity,*owner=&a->source->identity;
    if(original->st_uid!=geteuid() ||
       !content_metadata(original,&c->disk.identity) || (owner->st_mode&07000))return -1;
    if(!empty(a->source,error) || !empty(&c->disk,error)) {
        *error="publication-metadata-media";return -1;
    }
    *error="publication-metadata-precondition";
    if(!hg_guest_write_authority_unchanged(a) || !hg_guest_disk_unchanged(&c->disk) ||
       !position(i,c,a,error))return -1;
    int private_metadata=c->disk.identity.st_uid==original->st_uid &&
        c->disk.identity.st_gid==original->st_gid && (c->disk.identity.st_mode&07777)==0600;
    int handed_metadata=c->disk.identity.st_uid==owner->st_uid &&
        c->disk.identity.st_gid==owner->st_gid && (c->disk.identity.st_mode&07777)==(owner->st_mode&0777);
    if(!private_metadata && !handed_metadata)return -1;
    uid_t uid=restore?original->st_uid:owner->st_uid;
    gid_t gid=restore?original->st_gid:owner->st_gid;
    mode_t mode=restore?0600:owner->st_mode&0777;
    struct stat before=c->disk.identity,after;
    // Mark BEFORE the first syscall: errors can leave partially changed metadata.
    c->mutation_failed=1;*error="publication-metadata-write";
    if(fchown(c->disk.fd,uid,gid) || fchmod(c->disk.fd,mode) || fsync(c->disk.fd) ||
       fsync(c->directory_fd) || fstat(c->disk.fd,&after) || !content_metadata(&before,&after) ||
       after.st_uid!=uid || after.st_gid!=gid || (after.st_mode&07777)!=mode || !no_acl(c->disk.fd) ||
       !hg_guest_write_authority_unchanged(a) || !position(i,c,a,error))return -1;
    c->disk.identity=after;c->mutation_failed=0;*error=NULL;return 0;
}
