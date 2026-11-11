/* Authored-image evidence only. Records/inspects intent, never exchanges files.
 * principal UID here is test-supplied, not kernel caller attestation. */
#include "HGGuestPublicationIntent.h"
#include "HGGuestRoleWrite.h"
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv) {
    if(argc!=4 && argc!=5)return 64;
    int discard=argc==5 && !strcmp(argv[1],"discard");
    int inspect=discard || (argc==5 && !strcmp(argv[1],"inspect"));
    if(!inspect && argc!=4)return 64;
    if(!inspect && strcmp(argv[1],"prepare") && strcmp(argv[1],"neutral") && strcmp(argv[1],"tainted"))return 64;
    int incoming=open(argv[2],O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    int witness=open(argv[2],O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    int parent=open(argv[3],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    HGGuestDisk source={.fd=-1};HGGuestClone clone=HG_GUEST_CLONE_INIT;
    HGGuestWorkspace workspace=HG_GUEST_WORKSPACE_INIT;
    HGGuestWriteAuthority authority=HG_GUEST_WRITE_AUTHORITY_INIT;
    HGGuestPublicationIntent intent=HG_GUEST_PUBLICATION_INTENT_INIT;
    HGGuestPublicationPair pair=HG_PUBLICATION_PAIR_UNKNOWN;
    const char *error=NULL;
    int status=hg_guest_disk_inspect_fd(incoming,&source,&error);
    if(!status)status=hg_guest_write_authority_open(&source,witness,geteuid(),&authority,&error);
    if(!status)status=inspect?hg_guest_workspace_open(parent,argv[4],&workspace,&error):
                             hg_guest_workspace_create(parent,&source,&workspace,&error);
    if(!status && !inspect)status=hg_guest_clone_create(&source,workspace.directory_fd,&clone,&error);
    if(!status && !strcmp(argv[1],"neutral")) {
        HGGuestRoleWriteReport report={0};status=hg_guest_roles_write(&clone,0,&report,&error);
    }
    if(!status && !strcmp(argv[1],"tainted"))clone.mutation_failed=1;
    char payload[65];memset(payload,'a',64);payload[64]=0;
    if(!status && discard)status=hg_guest_workspace_discard(&workspace,&error);
    if(!status && !discard)status=inspect?hg_guest_publication_intent_open(&workspace,&intent,&error):
        hg_guest_publication_intent_create(&workspace,&clone,&authority,payload,&intent,&error);
    if(!status && !discard)status=hg_guest_publication_intent_pair(&intent,authority.directory_fd,&pair,&error);
    printf("{\"passed\":%s,\"error\":\"%s\",\"workspace\":\"%s\",\"clone\":\"%s\","
           "\"pair\":%d,\"source_unchanged\":%s,\"intent_opened\":%s}\n",
           status?"false":"true",error?error:"",workspace.name,clone.name,(int)pair,
           hg_guest_disk_unchanged(&source)?"true":"false",intent.record_fd>=0?"true":"false");
    fflush(stdout);
    /* Deliberately preserve intent and both files across process exit. */
    _exit(status?1:0);
}
