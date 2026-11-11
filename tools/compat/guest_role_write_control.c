/* Authored-image control only: private clone role roundtrip; never mounts. */
#include "HGGuestRoleWrite.h"
#include "HGGuestAPFS.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static int equal_files(const HGGuestDisk *a,const HGGuestDisk *b) {
    unsigned char left[65536],right[65536];
    for (off_t offset=0;offset<a->identity.st_size;) {
        size_t n=(size_t)(a->identity.st_size-offset);
        if (n>sizeof(left)) n=sizeof(left);
        if (pread(a->fd,left,n,offset)!=(ssize_t)n ||
            pread(b->fd,right,n,offset)!=(ssize_t)n || memcmp(left,right,n)) return 0;
        offset+=(off_t)n;
    }
    return hg_guest_disk_unchanged(a) && hg_guest_disk_unchanged(b);
}
int main(int argc,char **argv) {
    if (argc!=3) return 64;
    int incoming=open(argv[1],O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    int parent=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    HGGuestDisk source={.fd=-1};HGGuestClone clone=HG_GUEST_CLONE_INIT;
    HGGuestRoleWriteReport neutral={0},restore={0};HGGuestAPFS before={0},after={0};
    const char *error=NULL,*cleanup=NULL;
    int status=hg_guest_disk_inspect_fd(incoming,&source,&error);
    if (!status) status=hg_guest_apfs_inspect(&source,&before,&error);
    if (!status) status=hg_guest_clone_create(&source,parent,&clone,&error);
    if (!status) status=hg_guest_roles_write(&clone,0,&neutral,&error);
    if (!status) status=hg_guest_roles_write(&clone,1,&restore,&error);
    if (!status) status=hg_guest_apfs_inspect(&clone.disk,&after,&error);
    if (!status && memcmp(&before,&after,sizeof(before))) { status=-1;error="roundtrip-mismatch"; }
    int identical=!status && equal_files(&source,&clone.disk);
    if (!status && !identical) { status=-1;error="roundtrip-bytes-mismatch"; }
    int tainted=clone.mutation_failed;
    /* A tainted copy must refuse any further role writes. */
    if (tainted) {
        HGGuestRoleWriteReport retry={0};const char *again=NULL;
        if (!hg_guest_roles_write(&clone,1,&retry,&again)) return 70;
    }
    int discarded=clone.source?hg_guest_clone_discard(&clone,&cleanup):0;
    printf("{\"passed\":%s,\"error\":\"%s\",\"cleanup_error\":\"%s\","
           "\"neutral_edits\":%u,\"restore_edits\":%u,\"journal_durable\":%s,"
           "\"tainted\":%s,\"byte_identical_roundtrip\":%s,\"discarded\":%s,\"source_unchanged\":%s,\"image_mounted\":false}\n",
           !status && !discarded?"true":"false",error?error:"",cleanup?cleanup:"",
           neutral.edited_blocks,restore.edited_blocks,neutral.journal_durable?"true":"false",
           tainted?"true":"false",identical?"true":"false",discarded?"false":"true",
           hg_guest_disk_unchanged(&source)?"true":"false");
    hg_guest_disk_close(&source);if(incoming>=0)close(incoming);if(parent>=0)close(parent);
    return status || discarded?1:0;
}
