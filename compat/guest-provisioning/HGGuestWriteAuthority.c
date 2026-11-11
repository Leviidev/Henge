#include "HGGuestWriteAuthority.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/acl.h>
#include <unistd.h>

static int inode(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static int no_acl(int fd) {
    errno=0;acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if (!acl) return errno==ENOENT;
    acl_entry_t entry;int valid=!acl_valid(acl);errno=0;
    int empty=valid && acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL;
    acl_free(acl);return empty;
}
static int source_file(const struct stat *st,const HGGuestDisk *source) {
    const struct stat *original=&source->identity;
    return S_ISREG(st->st_mode) && st->st_nlink==1 && !st->st_flags && inode(st,original) &&
        st->st_size==original->st_size && st->st_uid==original->st_uid &&
        st->st_gid==original->st_gid && st->st_mode==original->st_mode &&
        st->st_mtimespec.tv_sec==original->st_mtimespec.tv_sec &&
        st->st_mtimespec.tv_nsec==original->st_mtimespec.tv_nsec &&
        st->st_ctimespec.tv_sec==original->st_ctimespec.tv_sec &&
        st->st_ctimespec.tv_nsec==original->st_ctimespec.tv_nsec;
}
int hg_guest_write_authority_unchanged(const HGGuestWriteAuthority *a) {
    if (!a || !a->source || a->directory_fd<0 || a->witness_fd<0 || !a->name[0] ||
        a->source->identity.st_uid!=a->principal_uid || !hg_guest_disk_unchanged(a->source)) return 0;
    struct stat parent,witness,named;
    int flags=fcntl(a->witness_fd,F_GETFL);
    if (flags<0 || (flags&O_ACCMODE)!=O_RDWR || (flags&O_APPEND) ||
        fstat(a->directory_fd,&parent) || !S_ISDIR(parent.st_mode) ||
        !inode(&parent,&a->directory_identity) || parent.st_uid!=a->source->identity.st_uid ||
        (parent.st_mode&0300)!=0300 || (parent.st_mode&0022) || parent.st_flags ||
        !no_acl(a->directory_fd) || fstat(a->witness_fd,&witness) ||
        !source_file(&witness,a->source) || !no_acl(a->witness_fd) ||
        fstatat(a->directory_fd,a->name,&named,AT_SYMLINK_NOFOLLOW) ||
        !source_file(&named,a->source)) return 0;
    return hg_guest_disk_unchanged(a->source);
}
void hg_guest_write_authority_close(HGGuestWriteAuthority *a) {
    if (!a) return;
    if (a->witness_fd>=0) close(a->witness_fd);
    if (a->directory_fd>=0) close(a->directory_fd);
    *a=(HGGuestWriteAuthority)HG_GUEST_WRITE_AUTHORITY_INIT;
}
int hg_guest_write_authority_open(const HGGuestDisk *source,int incoming,uid_t principal,
                                   HGGuestWriteAuthority *a,const char **error) {
    if (!a || !error) return -1;
    *error="write-authority-already-open";
    if (a->source || a->witness_fd>=0 || a->directory_fd>=0) return -1;
    *error="write-authority-descriptor";
    int flags=fcntl(incoming,F_GETFL);struct stat st;
    if (!source || source->identity.st_uid!=principal || !hg_guest_disk_unchanged(source) ||
        flags<0 || (flags&O_ACCMODE)!=O_RDWR || (flags&O_APPEND) ||
        fstat(incoming,&st) || !source_file(&st,source) || !no_acl(incoming)) return -1;
    char path[PATH_MAX];
    memset(path,0,sizeof(path));
    if (fcntl(incoming,F_GETPATH,path) || !memchr(path,0,sizeof(path)) || path[0]!='/') return -1;
    char *slash=strrchr(path,'/');
    if (!slash || !slash[1] || strlen(slash+1)>NAME_MAX ||
        !strcmp(slash+1,".") || !strcmp(slash+1,"..")) return -1;
    strcpy(a->name,slash+1);
    if (slash==path) path[1]=0;else *slash=0;
    a->directory_fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    a->witness_fd=fcntl(incoming,F_DUPFD_CLOEXEC,3);a->source=source;a->principal_uid=principal;
    if (a->directory_fd<0 || a->witness_fd<0 || fstat(a->directory_fd,&a->directory_identity) ||
        !hg_guest_write_authority_unchanged(a)) {
        hg_guest_write_authority_close(a);*error="write-authority-namespace";return -1;
    }
    *error=NULL;return 0;
}
