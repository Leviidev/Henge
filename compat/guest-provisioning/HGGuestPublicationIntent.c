#include "HGGuestPublicationIntent.h"
#include "HGGuestRoles.h"
#include "HGGuestMedia.h"
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <unistd.h>
#include <zlib.h>

static uint64_t get(const unsigned char *p) {
    uint64_t v=0;for(unsigned i=0;i<8;i++)v|=(uint64_t)p[i]<<(8*i);return v;
}
static void put(unsigned char *p,uint64_t v) {
    for(unsigned i=0;i<8;i++)p[i]=(unsigned char)(v>>(8*i));
}
static int inode(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static int hex(const char *p,size_t n) {
    for(size_t i=0;i<n;i++)if(!((p[i]>='0' && p[i]<='9') || (p[i]>='a' && p[i]<='f')))return 0;
    return 1;
}
static int no_acl(int fd) {
    errno=0;acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl)return errno==ENOENT;
    acl_entry_t entry;int good=!acl_valid(acl);errno=0;
    int empty=good && acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL;
    acl_free(acl);return empty;
}
static int valid(const unsigned char p[1024]) {
    const char *source=(const char *)p+160,*copy=(const char *)p+416,*payload=(const char *)p+480;
    size_t n=strnlen(source,256);
    if(memcmp(p,"HGPB0001",8) || get(p+1016)!=(uint64_t)crc32(0,p,1016) ||
       !get(p+16) || get(p+24)!=get(p+8) || get(p+40)!=get(p+8) || get(p+64)!=get(p+8) ||
       !get(p+32) || !get(p+48) || !get(p+72) || get(p+48)==get(p+72) ||
       get(p+56)<65536 || get(p+56)>INT64_MAX || get(p+56)%512 || get(p+80)!=get(p+56) ||
       get(p+88)>UINT32_MAX || get(p+96)>UINT32_MAX ||
       get(p+104)>UINT32_MAX || (get(p+104)&S_IFMT)!=S_IFREG || (get(p+104)&07000) ||
       get(p+120)>=1000000000 || get(p+136)>=1000000000 || get(p+144) || get(p+152) ||
       !n || n>=256 || strchr(source,'/') || !strcmp(source,".") || !strcmp(source,"..") ||
       strnlen(copy,64)!=32 || strncmp(copy,"henge-clone-",12) || !hex(copy+12,16) || strcmp(copy+28,".img") ||
       strnlen(payload,65)!=64 || !hex(payload,64))return 0;
    for(size_t i=160+n+1;i<416;i++)if(p[i])return 0;
    for(size_t i=449;i<480;i++)if(p[i])return 0;
    for(size_t i=545;i<1016;i++)if(p[i])return 0;
    return 1;
}
static int record_unchanged(const HGGuestPublicationIntent *i) {
    struct stat named,opened,directory;unsigned char p[1024];
    return i && i->directory_fd>=0 && i->record_fd>=0 && valid(i->record) &&
        !fstat(i->directory_fd,&directory) &&
        S_ISDIR(directory.st_mode) && directory.st_uid==geteuid() && !(directory.st_mode&0077) &&
        no_acl(i->directory_fd) &&
        (uint64_t)directory.st_dev==get(i->record+8) && (uint64_t)directory.st_ino==get(i->record+16) &&
        !fstat(i->record_fd,&opened) && !fstatat(i->directory_fd,"publication",&named,AT_SYMLINK_NOFOLLOW) &&
        inode(&named,&opened) && inode(&named,&i->record_identity) &&
        S_ISREG(opened.st_mode) && opened.st_uid==geteuid() && opened.st_nlink==1 &&
        opened.st_dev==directory.st_dev && (opened.st_mode&07777)==0600 && opened.st_size==1024 &&
        pread(i->record_fd,p,1024,0)==1024 && !memcmp(p,i->record,1024);
}
void hg_guest_publication_intent_close(HGGuestPublicationIntent *i) {
    if(!i)return;
    if(i->record_fd>=0)close(i->record_fd);
    if(i->directory_fd>=0)close(i->directory_fd);
    *i=(HGGuestPublicationIntent)HG_GUEST_PUBLICATION_INTENT_INIT;
}
int hg_guest_publication_intent_open(const HGGuestWorkspace *w,
    HGGuestPublicationIntent *i,const char **error) {
    if(!w || !i || !error)return -1;
    *error="publication-intent-already-open";
    if(i->directory_fd>=0 || i->record_fd>=0)return -1;
    *error="publication-intent-invalid";
    if(!hg_guest_workspace_unchanged(w))return -1;
    i->directory_fd=fcntl(w->directory_fd,F_DUPFD_CLOEXEC,3);
    i->record_fd=openat(w->directory_fd,"publication",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(i->directory_fd<0 || i->record_fd<0 || fstat(i->record_fd,&i->record_identity) ||
       pread(i->record_fd,i->record,1024,0)!=1024 || !valid(i->record) ||
       get(i->record+8)!=(uint64_t)w->directory_identity.st_dev ||
       get(i->record+16)!=(uint64_t)w->directory_identity.st_ino ||
       get(i->record+40)!=(uint64_t)w->source_identity.identity.st_dev ||
       get(i->record+48)!=(uint64_t)w->source_identity.identity.st_ino ||
       get(i->record+56)!=(uint64_t)w->source_identity.identity.st_size || !record_unchanged(i)) {
        hg_guest_publication_intent_close(i);return -1;
    }
    *error=NULL;return 0;
}
static int empty(const HGGuestDisk *disk,const char **error) {
    char *media=NULL;int status=hg_guest_media_copy(disk,&media,error);
    int result=!status && media && !strcmp(media,"[]");free(media);return result;
}
int hg_guest_publication_intent_create(const HGGuestWorkspace *w,
    const HGGuestClone *c,const HGGuestWriteAuthority *a,const char *payload,
    HGGuestPublicationIntent *i,const char **error) {
    if(!w || !c || !a || !i || !error)return -1;
    *error="publication-intent-already-open";
    if(i->directory_fd>=0 || i->record_fd>=0)return -1;
    *error="publication-intent-precondition";
    if(!payload || strlen(payload)!=64 || !hex(payload,64) || c->source!=a->source ||
       !c->created || c->mutation_failed || !hg_guest_workspace_unchanged(w) ||
       strnlen(c->name,sizeof(c->name))!=32 ||
       !hg_guest_write_authority_unchanged(a) || !hg_guest_disk_unchanged(&c->disk) ||
       !inode(&w->source_identity.identity,&a->source->identity) ||
       w->source_identity.identity.st_size!=a->source->identity.st_size ||
       c->disk.identity.st_dev!=a->source->identity.st_dev ||
       c->disk.identity.st_ino==a->source->identity.st_ino ||
       c->disk.identity.st_size!=a->source->identity.st_size ||
       c->disk.identity.st_uid!=geteuid() || (c->disk.identity.st_mode&07777)!=0600 ||
       c->disk.identity.st_nlink!=1 || c->disk.identity.st_flags || !no_acl(c->disk.fd) ||
       (a->source->identity.st_mode&07000))return -1;
    struct stat directory,named,parent;
    if(fstat(c->directory_fd,&directory) || !inode(&directory,&w->directory_identity) ||
       fstat(w->directory_fd,&directory) || !inode(&directory,&w->directory_identity) ||
       fstat(a->directory_fd,&parent) || parent.st_dev!=directory.st_dev ||
       fstatat(c->directory_fd,c->name,&named,AT_SYMLINK_NOFOLLOW) || !inode(&named,&c->created_identity) ||
       !inode(&named,&c->disk.identity))return -1;
    HGGuestAPFSCatalog *original=NULL,*copy=NULL;HGGuestRolePlan *plan=NULL;
    int failed=hg_guest_apfs_copy_catalog(a->source,&original,error) ||
        hg_guest_apfs_copy_catalog(&c->disk,&copy,error) ||
        hg_guest_roles_plan(original,copy,1,&plan,error);
    if(!failed && plan->count){*error="publication-roles-not-restored";failed=1;}
    free(original);free(copy);free(plan);
    if(failed)return -1;
    if(!empty(a->source,error) || !empty(&c->disk,error)) {
        *error="publication-media-cleanup-required";return -1;
    }
    unsigned char p[1024]={0};memcpy(p,"HGPB0001",8);
    put(p+8,(uint64_t)directory.st_dev);put(p+16,(uint64_t)directory.st_ino);
    put(p+24,(uint64_t)parent.st_dev);put(p+32,(uint64_t)parent.st_ino);
    const struct stat *s=&a->source->identity,*t=&c->disk.identity;
    put(p+40,(uint64_t)s->st_dev);put(p+48,(uint64_t)s->st_ino);put(p+56,(uint64_t)s->st_size);
    put(p+64,(uint64_t)t->st_dev);put(p+72,(uint64_t)t->st_ino);put(p+80,(uint64_t)t->st_size);
    put(p+88,s->st_uid);put(p+96,s->st_gid);put(p+104,s->st_mode);
    put(p+112,(uint64_t)s->st_mtimespec.tv_sec);put(p+120,(uint64_t)s->st_mtimespec.tv_nsec);
    put(p+128,(uint64_t)t->st_mtimespec.tv_sec);put(p+136,(uint64_t)t->st_mtimespec.tv_nsec);
    put(p+144,s->st_flags);strcpy((char *)p+160,a->name);strcpy((char *)p+416,c->name);
    memcpy(p+480,payload,64);put(p+1016,(uint64_t)crc32(0,p,1016));
    *error="publication-intent-precondition";
    if(!valid(p) || !hg_guest_workspace_unchanged(w) ||
       !hg_guest_write_authority_unchanged(a) || !hg_guest_disk_unchanged(&c->disk))return -1;
    int fd=openat(w->directory_fd,"publication",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    *error="publication-intent-create";
    if(fd<0)return -1;
    unsigned char check[1024];
    failed=fchmod(fd,0600) || pwrite(fd,p,1024,0)!=1024 || fsync(fd) ||
        fsync(w->directory_fd) || pread(fd,check,1024,0)!=1024 || memcmp(p,check,1024);
    close(fd);
    *error="publication-intent-sync";
    if(failed)return -1;
    if(hg_guest_publication_intent_open(w,i,error))return -1;
    if(!hg_guest_write_authority_unchanged(a) || !hg_guest_disk_unchanged(&c->disk)) {
        hg_guest_publication_intent_close(i);*error="publication-source-changed";return -1;
    }
    *error=NULL;return 0;
}
int hg_guest_publication_intent_pair(const HGGuestPublicationIntent *i,int parent,
    HGGuestPublicationPair *pair,const char **error) {
    if(!pair || !error)return -1;
    *pair=HG_PUBLICATION_PAIR_UNKNOWN;*error="publication-pair-invalid";
    if(!record_unchanged(i))return -1;
    struct stat directory,active,private;
    const unsigned char *p=i->record;
    if(fstat(parent,&directory) || !S_ISDIR(directory.st_mode) ||
       (uint64_t)directory.st_dev!=get(p+24) || (uint64_t)directory.st_ino!=get(p+32) ||
       fstatat(parent,(const char *)p+160,&active,AT_SYMLINK_NOFOLLOW) ||
       fstatat(i->directory_fd,(const char *)p+416,&private,AT_SYMLINK_NOFOLLOW) ||
       !S_ISREG(active.st_mode) || !S_ISREG(private.st_mode) || active.st_nlink!=1 || private.st_nlink!=1 ||
       (uint64_t)active.st_dev!=get(p+40) || (uint64_t)private.st_dev!=get(p+40) ||
       (uint64_t)active.st_size!=get(p+56) || (uint64_t)private.st_size!=get(p+56))return -1;
    if((uint64_t)active.st_ino==get(p+48) && (uint64_t)private.st_ino==get(p+72))
        *pair=HG_PUBLICATION_ORIGINAL_ACTIVE;
    else if((uint64_t)active.st_ino==get(p+72) && (uint64_t)private.st_ino==get(p+48))
        *pair=HG_PUBLICATION_COPY_ACTIVE;
    else return -1;
    *error=NULL;return 0;
}
