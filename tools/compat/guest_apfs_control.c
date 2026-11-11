/* Developer read-only checkpoint/volume identity control. */
#include "HGGuestAPFS.h"
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
static void uuid(const unsigned char *p) {
    for (unsigned int i=0;i<16;i++) {
        if (i==4 || i==6 || i==8 || i==10) putchar('-');
        printf("%02X",p[i]);
    }
}
int main(int argc,char **argv) {
    if (argc!=2) return 64;
    int fd=open(argv[1],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    HGGuestDisk disk={.fd=-1};HGGuestAPFS apfs={0};const char *error=NULL;
    int result=hg_guest_disk_inspect_fd(fd,&disk,&error);
    if (!result) result=hg_guest_apfs_inspect(&disk,&apfs,&error);
    printf("{\"passed\":%s,\"error\":\"%s\",\"block_size\":%u,\"checkpoint_xid\":%llu,\"volumes\":[",
           result?"false":"true",error?error:"",apfs.block_size,(unsigned long long)apfs.checkpoint_xid);
    for (unsigned int i=0;i<apfs.volume_count;i++) {
        HGGuestAPFSVolume *v=&apfs.volumes[i];
        printf("%s{\"oid\":%llu,\"xid\":%llu,\"physical_block\":%llu,\"role\":%u,\"flags\":%llu,\"uuid\":\"",
               i?",":"",(unsigned long long)v->oid,(unsigned long long)v->xid,
               (unsigned long long)v->physical_block,v->role,(unsigned long long)v->flags);
        uuid(v->uuid);printf("\",\"group_uuid\":\"");uuid(v->group_uuid);printf("\"}");
    }
    printf("],\"image_modified\":false}\n");
    hg_guest_disk_close(&disk);if(fd>=0)close(fd);return result?1:0;
}
