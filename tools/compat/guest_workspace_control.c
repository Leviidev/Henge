/* Authored-image only. create/hold intentionally leave an unpublished copy for
 * recovery by another process. No mount, replay or publication commands. */
#include "HGGuestWorkspace.h"
#include "HGGuestClone.h"
#include "HGGuestRoleWrite.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc,char **argv) {
    if (argc!=4) return 64;
    const char *error=NULL;
    HGGuestWorkspace workspace=HG_GUEST_WORKSPACE_INIT;
    if (!strcmp(argv[1],"create") || !strcmp(argv[1],"hold") || !strcmp(argv[1],"roles")) {
        int incoming=open(argv[2],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
        int parent=open(argv[3],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        HGGuestDisk source={.fd=-1};HGGuestClone clone=HG_GUEST_CLONE_INIT;
        int status=hg_guest_disk_inspect_fd(incoming,&source,&error);
        if (!status) status=hg_guest_workspace_create(parent,&source,&workspace,&error);
        if (!status) status=hg_guest_clone_create(&source,workspace.directory_fd,&clone,&error);
        if (!status && !strcmp(argv[1],"roles")) {
            HGGuestRoleWriteReport report={0};
            status=hg_guest_roles_write(&clone,0,&report,&error);
        }
        printf("{\"passed\":%s,\"workspace\":\"%s\",\"clone\":\"%s\",\"error\":\"%s\"}\n",
               status?"false":"true",workspace.name,clone.name,error?error:"");fflush(stdout);
        if (!status && !strcmp(argv[1],"hold")) (void)getchar();
        /* Emulate process death: do not execute cleanup or close destructors. */
        _exit(status?1:0);
    }
    int retry=!strcmp(argv[1],"recover-retry");
    if (strcmp(argv[1],"recover") && !retry) return 64;
    int parent=open(argv[2],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    int status=hg_guest_workspace_open(parent,argv[3],&workspace,&error);
    if (!status) status=hg_guest_workspace_discard(&workspace,&error);
    const char *first=error;
    if (status && retry && workspace.directory_fd>=0)
        status=hg_guest_workspace_discard(&workspace,&error);
    printf("{\"passed\":%s,\"error\":\"%s\",\"first_error\":\"%s\"}\n",
           status?"false":"true",error?error:"",first?first:"");
    hg_guest_workspace_close(&workspace);if(parent>=0)close(parent);return status?1:0;
}
