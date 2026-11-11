#include "HGGuestWorkspace.h"
#include "HGGuestMedia.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/file.h>
#include <unistd.h>
#include <zlib.h>

#define MAX_FILES 128
static uint64_t get(const unsigned char *p) {
    uint64_t v=0;for (unsigned i=0;i<8;i++) v|=(uint64_t)p[i]<<(8*i);return v;
}
static void put(unsigned char *p,uint64_t v) {
    for (unsigned i=0;i<8;i++) p[i]=(unsigned char)(v>>(8*i));
}
static int hex(const char *p,size_t n) {
    for (size_t i=0;i<n;i++) if (!((p[i]>='0' && p[i]<='9') || (p[i]>='a' && p[i]<='f'))) return 0;
    return 1;
}
static int workspace_name(const char *p) {
    return p && strlen(p)==26 && !strncmp(p,"henge-txn-",10) && hex(p+10,16);
}
static int file_kind(const char *p) {
    size_t n=strlen(p);
    if ((n!=32 && n!=55) || strncmp(p,"henge-clone-",12) || !hex(p+12,16) ||
        strncmp(p+28,".img",4)) return 0;
    return n==32?1:(!strncmp(p+32,".roles-",7) && hex(p+39,16)?2:0);
}
static int inode(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static int private_directory(int fd,struct stat *st) {
    if (fstat(fd,st) || !S_ISDIR(st->st_mode) || st->st_uid!=geteuid() || (st->st_mode&0077)) return 0;
    errno=0;
    acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    /* Darwin reports ENOENT for no extended ACL on an already valid FD. Other
     * failures (including unsupported retrieval) cannot prove privacy. */
    if (!acl) return errno==ENOENT;
    acl_entry_t entry;int valid=!acl_valid(acl);
    errno=0;
    int empty=valid && acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL;
    acl_free(acl);return empty;
}
static int named_directory(const HGGuestWorkspace *w) {
    struct stat st,opened,parent;
    return private_directory(w->parent_fd,&parent) && private_directory(w->directory_fd,&opened) &&
        inode(&opened,&w->directory_identity) && opened.st_dev==parent.st_dev &&
        !fstatat(w->parent_fd,w->name,&st,AT_SYMLINK_NOFOLLOW) &&
        S_ISDIR(st.st_mode) && inode(&opened,&st);
}
static void receipt(const HGGuestWorkspace *w,unsigned char p[96]) {
    memset(p,0,96);memcpy(p,"HGWS0001",8);
    put(p+8,(uint64_t)w->directory_identity.st_dev);put(p+16,(uint64_t)w->directory_identity.st_ino);
    put(p+24,(uint64_t)w->source_identity.identity.st_dev);
    put(p+32,(uint64_t)w->source_identity.identity.st_ino);
    put(p+40,(uint64_t)w->source_identity.identity.st_size);
    put(p+48,w->source_identity.first_apfs_lba);put(p+56,w->source_identity.last_apfs_lba);
    memcpy(p+64,w->source_identity.disk_uuid,16);put(p+80,(uint64_t)crc32(0,p,80));
}
static int read_receipt(HGGuestWorkspace *w,struct stat *identity) {
    int fd=openat(w->directory_fd,"owner",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    unsigned char p[96],expected[96];int good=0;
    if (fd<0) return -1;
    if (fstat(fd,identity) || identity->st_dev!=w->directory_identity.st_dev ||
        !S_ISREG(identity->st_mode) || identity->st_uid!=geteuid() ||
        identity->st_nlink!=1 || (identity->st_mode&07777)!=0600 || identity->st_size!=96 ||
        pread(fd,p,96,0)!=96 || memcmp(p,"HGWS0001",8) ||
        get(p+8)!=(uint64_t)w->directory_identity.st_dev ||
        get(p+16)!=(uint64_t)w->directory_identity.st_ino ||
        get(p+80)!=(uint64_t)crc32(0,p,80) || get(p+88)) goto done;
    w->source_identity.identity.st_dev=(dev_t)get(p+24);
    w->source_identity.identity.st_ino=(ino_t)get(p+32);
    uint64_t size=get(p+40);
    if (size<65536 || size>INT64_MAX || size%512) goto done;
    w->source_identity.identity.st_size=(off_t)size;
    w->source_identity.first_apfs_lba=get(p+48);w->source_identity.last_apfs_lba=get(p+56);
    memcpy(w->source_identity.disk_uuid,p+64,16);
    if (w->source_identity.first_apfs_lba<2 ||
        w->source_identity.first_apfs_lba>w->source_identity.last_apfs_lba ||
        w->source_identity.last_apfs_lba>=size/512) goto done;
    receipt(w,expected);good=!memcmp(p,expected,96);
done:
    close(fd);return good?0:-1;
}
void hg_guest_workspace_close(HGGuestWorkspace *w) {
    if (!w) return;
    if (w->directory_fd>=0) close(w->directory_fd);
    if (w->parent_fd>=0) close(w->parent_fd);
    *w=(HGGuestWorkspace)HG_GUEST_WORKSPACE_INIT;
}
static int start(int parent,HGGuestWorkspace *w,const char **error) {
    if (!w || !error) return -1;
    *error="workspace-already-open";
    if (w->parent_fd>=0 || w->directory_fd>=0) return -1;
    int fd=fcntl(parent,F_DUPFD_CLOEXEC,3);struct stat st;
    if (fd<0 || !private_directory(fd,&st)) {
        if (fd>=0) close(fd);
        *error="workspace-parent";return -1;
    }
    w->parent_fd=fd;return 0;
}
int hg_guest_workspace_create(int parent,const HGGuestDisk *source,
                               HGGuestWorkspace *w,const char **error) {
    if (start(parent,w,error)) return -1;
    *error="workspace-source";
    if (!hg_guest_disk_unchanged(source)) goto fail;
    for (unsigned i=0;i<8;i++) {
        uint64_t nonce;arc4random_buf(&nonce,sizeof(nonce));
        snprintf(w->name,sizeof(w->name),"henge-txn-%016llx",(unsigned long long)nonce);
        if (!mkdirat(w->parent_fd,w->name,0700)) break;
        if (errno!=EEXIST || i==7) { *error="workspace-create";goto fail; }
    }
    w->directory_fd=openat(w->parent_fd,w->name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    *error="workspace-identity";
    if (w->directory_fd<0 || !private_directory(w->directory_fd,&w->directory_identity) ||
        !named_directory(w) || flock(w->directory_fd,LOCK_EX|LOCK_NB)) goto fail;
    w->source_identity=*source;w->source_identity.fd=-1;
    unsigned char p[96];receipt(w,p);
    int fd=openat(w->directory_fd,"owner",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    *error="workspace-receipt-create";
    if (fd<0) goto fail;
    int failed=fchmod(fd,0600) || pwrite(fd,p,96,0)!=96 || fsync(fd);
    close(fd);
    *error="workspace-receipt-sync";
    if (failed || fsync(w->directory_fd) || fsync(w->parent_fd) ||
        !named_directory(w) || !hg_guest_disk_unchanged(source)) goto fail;
    *error=NULL;return 0;
fail:
    /* No heavy artifact may be created until success. Unknown or incomplete
     * receipt directories are preserved, never inferred to be safe to delete. */
    hg_guest_workspace_close(w);return -1;
}
int hg_guest_workspace_open(int parent,const char *name,HGGuestWorkspace *w,const char **error) {
    if (!workspace_name(name)) { if(error)*error="workspace-name";return -1; }
    if (start(parent,w,error)) return -1;
    memcpy(w->name,name,27);
    w->directory_fd=openat(w->parent_fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    *error="workspace-identity";
    if (w->directory_fd<0 || !private_directory(w->directory_fd,&w->directory_identity) || !named_directory(w)) goto fail;
    *error="workspace-in-use";
    if (flock(w->directory_fd,LOCK_EX|LOCK_NB)) goto fail;
    struct stat st;*error="workspace-receipt-invalid";
    if (read_receipt(w,&st)) goto fail;
    *error=NULL;return 0;
fail:
    hg_guest_workspace_close(w);return -1;
}

typedef struct { char name[64];HGGuestDisk file;int kind; } Entry;
static int namespace_matches(const HGGuestWorkspace *w,const Entry *entries,unsigned count) {
    int fd=openat(w->directory_fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *dir=fd>=0?fdopendir(fd):NULL;
    if (!dir) { if(fd>=0)close(fd);return 0; }
    unsigned char seen[MAX_FILES]={0};unsigned found=0;int owner=0,good=1;
    struct dirent *de;errno=0;
    while ((de=readdir(dir))) {
        if (!strcmp(de->d_name,".") || !strcmp(de->d_name,"..")) continue;
        if (!strcmp(de->d_name,"owner")) { if(owner++){good=0;break;}continue; }
        unsigned i=0;
        for (;i<count;i++) if (!strcmp(entries[i].name,de->d_name)) break;
        if (i==count || seen[i]) { good=0;break; }
        seen[i]=1;found++;
    }
    if (errno) good=0;
    closedir(dir);return good && owner==1 && found==count;
}
int hg_guest_workspace_discard(HGGuestWorkspace *w,const char **error) {
    if (!w || !error || w->parent_fd<0 || w->directory_fd<0) return -1;
    *error="workspace-identity";
    if (!w->removed && !named_directory(w)) return -1;
    if (w->removed) {
        if (fsync(w->parent_fd)) { *error="workspace-parent-sync";return -1; }
        hg_guest_workspace_close(w);*error=NULL;return 0;
    }
    if (w->cleared) goto remove_directory;
    struct stat owner;*error="workspace-receipt-invalid";
    if (read_receipt(w,&owner)) return -1;
    Entry *entries=calloc(MAX_FILES,sizeof(*entries));
    if (!entries) { *error="workspace-allocation";return -1; }
    unsigned count=0;int result=-1;char basename[33]={0};int images=0;
    int scan=openat(w->directory_fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    DIR *dir=scan>=0?fdopendir(scan):NULL;
    if (!dir) { if(scan>=0)close(scan);*error="workspace-enumeration";goto done; }
    struct dirent *de;*error="workspace-entry-unknown";errno=0;
    while ((de=readdir(dir))) {
        if (!strcmp(de->d_name,".") || !strcmp(de->d_name,"..") || !strcmp(de->d_name,"owner")) continue;
        int kind=file_kind(de->d_name);
        if (!kind || count==MAX_FILES || (kind==1 && images++)) goto done;
        if (basename[0] && strncmp(basename,de->d_name,32)) goto done;
        memcpy(basename,de->d_name,32);
        Entry *e=&entries[count];e->file.fd=-1;
        memcpy(e->name,de->d_name,strlen(de->d_name)+1);e->kind=kind;
        e->file.fd=openat(w->directory_fd,e->name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
        struct stat named;
        if (e->file.fd<0) goto done;
        count++;
        if (fstat(e->file.fd,&e->file.identity) ||
            fstatat(w->directory_fd,e->name,&named,AT_SYMLINK_NOFOLLOW) ||
            !inode(&named,&e->file.identity) || !S_ISREG(named.st_mode) || named.st_nlink!=1 ||
            named.st_uid!=geteuid() || named.st_dev!=w->directory_identity.st_dev ||
            (named.st_mode&07000) || inode(&named,&w->source_identity.identity) ||
            (kind==1 ? named.st_size!=w->source_identity.identity.st_size :
                       (named.st_size<0 || named.st_size>32*1024*1024))) goto done;
        *error="workspace-file-in-use";
        if (flock(e->file.fd,LOCK_EX|LOCK_NB)) goto done;
        *error="workspace-entry-unknown";errno=0;
    }
    if (errno) { *error="workspace-enumeration";goto done; }
    closedir(dir);dir=NULL;
    for (unsigned i=0;i<count;i++) if (entries[i].kind==1) {
        HGGuestDisk *disk=&entries[i].file;
        disk->first_apfs_lba=w->source_identity.first_apfs_lba;
        disk->last_apfs_lba=w->source_identity.last_apfs_lba;
        memcpy(disk->disk_uuid,w->source_identity.disk_uuid,16);
        char *media=NULL;int status=hg_guest_media_copy(disk,&media,error);
        int empty=!status && media && !strcmp(media,"[]");free(media);
        if (!empty) { *error="workspace-media-cleanup-required";goto done; }
    }
    /* Inventory can run arbitrary system code. Revalidate all names afterwards,
     * including the receipt, before the first unlink. Never follow links. */
    struct stat named,again;
    if (!named_directory(w) || read_receipt(w,&again) || !inode(&owner,&again)) {
        *error="workspace-identity";goto done;
    }
    for (unsigned i=0;i<count;i++) {
        Entry *e=&entries[i];
        if (fstatat(w->directory_fd,e->name,&named,AT_SYMLINK_NOFOLLOW) ||
            !inode(&named,&e->file.identity) || !hg_guest_disk_unchanged(&e->file)) {
            *error="workspace-entry-changed";goto done;
        }
    }
    if (!namespace_matches(w,entries,count)) { *error="workspace-namespace-changed";goto done; }
    /* Every deletion targets a preflighted file. New unknown entries remain and
     * prevent rmdir; cleanup never recurses through them. */
    for (int kind=1;kind<=2;kind++) {
        for (unsigned i=0;i<count;i++) if (entries[i].kind==kind) {
            Entry *e=&entries[i];
            if (fstatat(w->directory_fd,e->name,&named,AT_SYMLINK_NOFOLLOW) ||
                !inode(&named,&e->file.identity) || unlinkat(w->directory_fd,e->name,0)) {
                *error="workspace-unlink";goto done;
            }
        }
        if (fsync(w->directory_fd)) { *error="workspace-directory-sync";goto done; }
    }
    if (!namespace_matches(w,NULL,0)) { *error="workspace-namespace-changed";goto done; }
    if (fstatat(w->directory_fd,"owner",&named,AT_SYMLINK_NOFOLLOW) ||
        !inode(&owner,&named) || unlinkat(w->directory_fd,"owner",0)) {
        *error="workspace-receipt-unlink";goto done;
    }
    w->cleared=1;result=0;
done:
    if (dir) closedir(dir);
    for (unsigned i=0;i<count;i++) hg_guest_disk_close(&entries[i].file);
    free(entries);
    if (result) return -1;
remove_directory:
    if (fsync(w->directory_fd)) { *error="workspace-directory-sync";return -1; }
    if (!named_directory(w) || unlinkat(w->parent_fd,w->name,AT_REMOVEDIR)) {
        *error="workspace-remove";return -1;
    }
    w->removed=1;
    if (fsync(w->parent_fd)) { *error="workspace-parent-sync";return -1; }
    hg_guest_workspace_close(w);*error=NULL;return 0;
}
