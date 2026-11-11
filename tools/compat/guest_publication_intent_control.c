/* Authored-image evidence only. Can restore authored image pairs atomically,
 * change private copy metadata and quarantine authored RAM after durable intent.
 * principal UID here is test-supplied, not kernel caller attestation. */
#include "HGGuestPublicationIntent.h"
#include "HGGuestRoleWrite.h"
#include "HGGuestPublicationMetadata.h"
#include "HGGuestSnapshotInvalidation.h"
#include "HGGuestPublicationRollback.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv) {
    if(argc!=4 && argc!=5)return 64;
    int discard=argc==5 && !strcmp(argv[1],"discard");
    int inspect=discard || (argc==5 && (!strcmp(argv[1],"inspect") || !strcmp(argv[1],"snapshot-inspect") || !strcmp(argv[1],"snapshot-complete") || !strcmp(argv[1],"rollback")));
    if(!inspect && argc!=4)return 64;
    if(!inspect && strcmp(argv[1],"prepare") && strcmp(argv[1],"neutral") && strcmp(argv[1],"tainted") && strcmp(argv[1],"handoff") && strcmp(argv[1],"handoff-restore") && strcmp(argv[1],"handoff-twice") && strcmp(argv[1],"snapshot") && strcmp(argv[1],"ready"))return 64;
    int incoming=open(argv[2],O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    int witness=open(argv[2],O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    int parent=open(argv[3],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    HGGuestDisk source={.fd=-1};HGGuestClone clone=HG_GUEST_CLONE_INIT;
    HGGuestWorkspace workspace=HG_GUEST_WORKSPACE_INIT;
    HGGuestWriteAuthority authority=HG_GUEST_WRITE_AUTHORITY_INIT;
    HGGuestPublicationIntent intent=HG_GUEST_PUBLICATION_INTENT_INIT;
    HGGuestPublicationPair pair=HG_PUBLICATION_PAIR_UNKNOWN;
    HGGuestRollbackReport rollback={0};
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
    if(!status && (!strcmp(argv[1],"handoff") || !strcmp(argv[1],"handoff-restore") || !strcmp(argv[1],"handoff-twice") || !strcmp(argv[1],"ready"))) {
        status=hg_guest_publication_metadata_set(&intent,&clone,&authority,0,&error);
        if(!status && !strcmp(argv[1],"handoff-twice"))
            status=hg_guest_publication_metadata_set(&intent,&clone,&authority,0,&error);
        if(!status && !strcmp(argv[1],"handoff-restore"))
            status=hg_guest_publication_metadata_set(&intent,&clone,&authority,1,&error);
    }
    if(!status && (!strcmp(argv[1],"snapshot") || !strcmp(argv[1],"ready")))
        status=hg_guest_snapshot_invalidate(&intent,&authority,&error);
    if(!status && !strcmp(argv[1],"snapshot-complete"))
        status=hg_guest_snapshot_invalidation_complete(&intent,&authority,&error);
    if(!status && !strcmp(argv[1],"snapshot-inspect"))
        status=hg_guest_snapshot_invalidation_verify(&intent,authority.directory_fd,&error);
    if(!status && !strcmp(argv[1],"rollback")) {
        HGGuestDisk private={.fd=-1};
        int fd=openat(intent.directory_fd,(const char *)intent.record+416,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        status=hg_guest_disk_inspect_fd(fd,&private,&error);if(fd>=0)close(fd);
        HGGuestPeer peer={.verified=1,.uid=geteuid()};
        const char *mode=getenv("HENGE_PUBLICATION_TEST");
        if(mode && !strcmp(mode,"rollback-wrong-uid"))peer.uid++;
        // The native test supplies a peer stub, not a real privileged app.
        if(!status)status=hg_guest_publication_rollback(&intent,&authority,&private,-1,&peer,&rollback,&error);
    }
    printf("{\"passed\":%s,\"error\":\"%s\",\"workspace\":\"%s\",\"clone\":\"%s\","
           "\"pair\":%d,\"source_unchanged\":%s,\"intent_opened\":%s,\"copy_tainted\":%s,\"exchange_attempted\":%s,\"rollback_durable\":%s,\"rollback_pair\":%d}\n",
           status?"false":"true",error?error:"",workspace.name,clone.name,(int)pair,
           hg_guest_disk_unchanged(&source)?"true":"false",intent.record_fd>=0?"true":"false",clone.mutation_failed?"true":"false",rollback.exchange_attempted?"true":"false",
           rollback.durability_confirmed?"true":"false",(int)rollback.observed_pair);
    fflush(stdout);
    /* Deliberately preserve intent and both files across process exit. */
    _exit(status?1:0);
}
