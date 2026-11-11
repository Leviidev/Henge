/* Read-only authored-image planner qualification. No mutation/mount authority. */
#include "HGGuestRoles.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc,char **argv) {
    if (argc!=4 || (strcmp(argv[3],"neutralize") && strcmp(argv[3],"restore"))) return 64;
    HGGuestDisk disks[2]={{.fd=-1},{.fd=-1}};
    HGGuestAPFSCatalog *catalogs[2]={NULL,NULL};
    HGGuestRolePlan *plan=NULL;const char *error=NULL;int status=-1;
    for (int i=0;i<2;i++) {
        int fd=open(argv[i+1],O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        if (fd<0) { error="control-image-open";goto done; }
        int failed=hg_guest_disk_inspect_fd(fd,&disks[i],&error);
        close(fd);
        if (failed || hg_guest_apfs_copy_catalog(&disks[i],&catalogs[i],&error)) goto done;
    }
    if (disks[0].first_apfs_lba!=disks[1].first_apfs_lba ||
        disks[0].last_apfs_lba!=disks[1].last_apfs_lba ||
        memcmp(disks[0].disk_uuid,disks[1].disk_uuid,16)) {
        error="control-image-geometry-mismatch";goto done;
    }
    status=hg_guest_roles_plan(catalogs[0],catalogs[1],!strcmp(argv[3],"restore"),&plan,&error);
    if (!status && (!hg_guest_disk_unchanged(&disks[0]) || !hg_guest_disk_unchanged(&disks[1]))) {
        status=-1;error="control-image-changed";
    }
done:
    printf("{\"passed\":%s,\"error\":\"%s\",\"planned_edits\":%u,\"image_modified\":false}\n",
           status?"false":"true",error?error:"",plan?plan->count:0);
    free(plan);
    for (int i=0;i<2;i++) { free(catalogs[i]);hg_guest_disk_close(&disks[i]); }
    return status?1:0;
}
