/* Authored-image control only. Optional external-write pauses allow a host
 * harness to mount/write/unmount the copy; this program never invokes tools. */
#include "HGGuestRoleWrite.h"
#include "HGGuestAPFS.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
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
static int external_pause(const HGGuestClone *clone,const char *phase,int unlock) {
    char path[4096],line[16];
    if (fcntl(clone->disk.fd,F_GETPATH,path)) return -1;
    /* Developer-only host hdiutil accommodation, never used by provisioning.
     * Source lease is retained. Caller must detach before replying GO. */
    if (unlock && flock(clone->disk.fd,LOCK_UN)) return -1;
    printf("%s %s\n",phase,path);fflush(stdout);
    int received=fgets(line,sizeof(line),stdin) && !strcmp(line,"GO\n");
    if (unlock && flock(clone->disk.fd,LOCK_EX|LOCK_NB)) return -1;
    return received?0:-1;
}
int main(int argc,char **argv) {
    int unlocked=argc==4 && !strcmp(argv[3],"--external-write-unlocked");
    int external=unlocked || (argc==4 && !strcmp(argv[3],"--external-write"));
    if (argc!=3 && !external) return 64;
    int incoming=open(argv[1],O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    int parent=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    HGGuestDisk source={.fd=-1};HGGuestClone clone=HG_GUEST_CLONE_INIT;
    HGGuestRoleWriteReport neutral={0},restore={0};HGGuestAPFS before={0},after={0};
    const char *error=NULL,*cleanup=NULL;
    int status=hg_guest_disk_inspect_fd(incoming,&source,&error);
    if (!status) status=hg_guest_apfs_inspect(&source,&before,&error);
    if (!status) status=hg_guest_clone_create(&source,parent,&clone,&error);
    if (!status) status=hg_guest_roles_write(&clone,0,&neutral,&error);
    if (!status && external && external_pause(&clone,"NEUTRAL",unlocked)) {
        status=-1;error="external-control-interrupted";
    }
    if (!status) status=hg_guest_roles_write(&clone,1,&restore,&error);
    if (!status && external) {
        HGGuestRoleWriteReport again={0};
        status=hg_guest_roles_write(&clone,1,&again,&error);
        if (!status && again.edited_blocks) { status=-1;error="restoration-not-idempotent"; }
    }
    if (!status && external && external_pause(&clone,"RESTORED",unlocked)) {
        status=-1;error="external-control-interrupted";
    }
    /* The second external pause may remount for readback, advancing checkpoints.
     * Refresh the identity only through the same owned write primitive's no-op
     * restoration path, which again requires detached media and source stability. */
    if (!status && external) {
        HGGuestRoleWriteReport again={0};
        status=hg_guest_roles_write(&clone,1,&again,&error);
    }
    if (!status) status=hg_guest_apfs_inspect(&clone.disk,&after,&error);
    if (!status && !external && memcmp(&before,&after,sizeof(before))) { status=-1;error="roundtrip-mismatch"; }
    int identical=!status && !external && equal_files(&source,&clone.disk);
    if (!status && !external && !identical) { status=-1;error="roundtrip-bytes-mismatch"; }
    int tainted=clone.mutation_failed;
    /* A tainted copy must refuse any further role writes. */
    if (tainted) {
        HGGuestRoleWriteReport retry={0};const char *again=NULL;
        if (!hg_guest_roles_write(&clone,1,&retry,&again)) return 70;
    }
    int discarded=clone.source?hg_guest_clone_discard(&clone,&cleanup):0;
    printf("{\"passed\":%s,\"error\":\"%s\",\"cleanup_error\":\"%s\","
           "\"neutral_edits\":%u,\"restore_edits\":%u,\"original_checkpoint_xid\":%llu,\"final_checkpoint_xid\":%llu,\"journal_durable\":%s,"
           "\"tainted\":%s,\"byte_identical_roundtrip\":%s,\"external_write_control\":%s,\"host_copy_lease_released\":%s,\"discarded\":%s,\"source_unchanged\":%s,\"image_mounted\":false}\n",
           !status && !discarded?"true":"false",error?error:"",cleanup?cleanup:"",
           neutral.edited_blocks,restore.edited_blocks,
           (unsigned long long)before.checkpoint_xid,(unsigned long long)after.checkpoint_xid,
           neutral.journal_durable?"true":"false",
           tainted?"true":"false",identical?"true":"false",external?"true":"false",unlocked?"true":"false",discarded?"false":"true",
           hg_guest_disk_unchanged(&source)?"true":"false");
    hg_guest_disk_close(&source);if(incoming>=0)close(incoming);if(parent>=0)close(parent);
    return status || discarded?1:0;
}
