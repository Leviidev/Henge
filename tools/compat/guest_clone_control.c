/* Developer-only COW/identity/discard control. Never mounts or publishes. */
#include "HGGuestClone.h"
#include "HGGuestAPFS.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv) {
    if (argc!=3) return 64;
    int incoming=open(argv[1],O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    int parent=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    HGGuestDisk source={.fd=-1};HGGuestClone clone=HG_GUEST_CLONE_INIT;
    HGGuestAPFS before={0},after={0};const char *error=NULL,*cleanup=NULL;
    int status=hg_guest_disk_inspect_fd(incoming,&source,&error);
    if (!status) status=hg_guest_apfs_inspect(&source,&before,&error);
    if (!status) status=hg_guest_clone_create(&source,parent,&clone,&error);
    int created=!status;
    if (!status) status=hg_guest_apfs_inspect(&clone.disk,&after,&error);
    int equal=created && !status && !memcmp(&before,&after,sizeof(before));
    if (!status && !equal) { error="clone-apfs-mismatch";status=-1; }
    int independent=created && (source.identity.st_dev!=clone.disk.identity.st_dev ||
                               source.identity.st_ino!=clone.disk.identity.st_ino);
    int closed=clone.source?hg_guest_clone_discard(&clone,&cleanup):0;
    printf("{\"passed\":%s,\"error\":\"%s\",\"cleanup_error\":\"%s\","
           "\"clone_created\":%s,\"independent_inode\":%s,\"apfs_metadata_identical\":%s,"
           "\"discarded\":%s,\"source_identity_unchanged\":%s,\"image_mounted\":false}\n",
           !status && !closed?"true":"false",error?error:"",cleanup?cleanup:"",
           created?"true":"false",independent?"true":"false",equal?"true":"false",
           !closed?"true":"false",hg_guest_disk_unchanged(&source)?"true":"false");
    hg_guest_disk_close(&source);if(incoming>=0)close(incoming);if(parent>=0)close(parent);
    return status || closed?1:0;
}
