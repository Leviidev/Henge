#import <Foundation/Foundation.h>
#include "HGGuestPayloadDelivery.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *components[]={"Library","Application Support","Henge","Compatibility"};
static int no_acl(int fd) {
    errno=0;acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    if(!acl)return errno==ENOENT;
    acl_entry_t entry;int good=!acl_valid(acl);errno=0;
    int empty=good && acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL;
    acl_free(acl);return empty;
}
static int directory(int fd,dev_t device,int public_path,struct stat *st) {
    return !fstat(fd,st) && S_ISDIR(st->st_mode) && st->st_dev==device &&
        st->st_uid==geteuid() && !st->st_flags && !(st->st_mode&07022) &&
        (st->st_mode&0300)==0300 && (!public_path || (st->st_mode&0005)==0005) && no_acl(fd);
}
static int namespace_matches(int fds[5],const struct stat identities[5]) {
    for(unsigned j=0;j<5;j++) {
        struct stat st,named;
        if(!directory(fds[j],identities[0].st_dev,j!=0,&st) ||
           st.st_ino!=identities[j].st_ino || st.st_mode!=identities[j].st_mode ||
           st.st_gid!=identities[j].st_gid)return 0;
        if(j && (fstatat(fds[j-1],components[j-1],&named,AT_SYMLINK_NOFOLLOW) ||
                 named.st_dev!=st.st_dev || named.st_ino!=st.st_ino || !S_ISDIR(named.st_mode)))return 0;
    }
    return 1;
}
int hg_guest_payload_deliver_data_root(const char *resources,const HGGuestPayloadIdentity *identity,
    int root,char **report) {
    if(report)*report=NULL;
    @autoreleasepool {
        NSString *failure=@"delivery-payload";
        int fds[5]={-1,-1,-1,-1,-1};struct stat identities[5];memset(identities,0,sizeof(identities));
        BOOL success=NO,may_change=NO;char *verified=NULL,*staged=NULL;
        NSMutableDictionary *result=[NSMutableDictionary dictionary];
        if(hg_guest_payload_verify_directory(resources,identity,&verified))goto done;
        fds[0]=fcntl(root,F_DUPFD_CLOEXEC,3);failure=@"delivery-data-root";
        if(fds[0]<0 || fstat(fds[0],&identities[0]) ||
           !directory(fds[0],identities[0].st_dev,0,&identities[0]))goto done;
        for(unsigned j=0;j<4;j++) {
            struct stat named;int created=0;
            failure=@"delivery-path";
            if(fstatat(fds[j],components[j],&named,AT_SYMLINK_NOFOLLOW)) {
                if(errno!=ENOENT)goto done;
                may_change=YES;
                if(mkdirat(fds[j],components[j],0755))goto done;
                created=1;
                if(fstatat(fds[j],components[j],&named,AT_SYMLINK_NOFOLLOW))goto done;
            }
            if(!S_ISDIR(named.st_mode) || named.st_dev!=identities[0].st_dev || named.st_uid!=geteuid())goto done;
            fds[j+1]=openat(fds[j],components[j],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if(fds[j+1]<0 || fstat(fds[j+1],&identities[j+1]) ||
               named.st_dev!=identities[j+1].st_dev || named.st_ino!=identities[j+1].st_ino)goto done;
            if(created && fchmod(fds[j+1],0755))goto done;
            if(!directory(fds[j+1],identities[0].st_dev,1,&identities[j+1]))goto done;
            failure=@"delivery-path-sync";
            // Sync even existing parents: a previous interrupted attempt may
            // have created this known directory without reaching its barrier.
            if(fsync(fds[j+1]) || fsync(fds[j]))goto done;
        }
        failure=@"delivery-namespace-changed";
        if(!namespace_matches(fds,identities))goto done;
        may_change=YES;failure=@"delivery-stage";
        if(hg_guest_payload_stage_directory(resources,identity,fds[4],&staged))goto done;
        failure=@"delivery-namespace-changed";
        if(!namespace_matches(fds,identities))goto done;
        for(unsigned j=0;j<5;j++)if(fsync(fds[j])){failure=@"delivery-path-sync";goto done;}
        if(!namespace_matches(fds,identities))goto done;
        success=YES;
    done:
        if(staged) {
            id object=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:staged length:strlen(staged)] options:0 error:NULL];
            if([object isKindOfClass:NSDictionary.class])[result addEntriesFromDictionary:object];
        } else if(verified) {
            id object=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:verified length:strlen(verified)] options:0 error:NULL];
            if([object isKindOfClass:NSDictionary.class])[result addEntriesFromDictionary:object];
        }
        [result removeObjectForKey:@"guest_disk_accessed"];
        result[@"schema"]=@1;result[@"operation"]=@"deliver-payload-v1";
        result[@"payload_delivered"]=@(success);result[@"data_tree_may_have_changed"]=@(may_change);
        result[@"activation_performed"]=@NO;result[@"mount_authority_established"]=@NO;
        result[@"relative_parent"]=@"Library/Application Support/Henge/Compatibility";
        if(!success)result[@"delivery_error"]=failure;
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        if(report && json)*report=strndup(json.bytes,json.length);
        free(verified);free(staged);
        for(unsigned j=0;j<5;j++)if(fds[j]>=0)close(fds[j]);
        return success?0:65;
    }
}
