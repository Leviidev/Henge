#import <Foundation/Foundation.h>
#include "HGGuestPeer.h"
#include "HGGuestCodeIdentity.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Exported Darwin SPI; declarations absent from the public iOS headers. Kernel
 * behavior: apple-oss-distributions/xnu, xnu-10002.1.13/bsd/kern/kern_proc.c. */
extern int proc_pidpath(int pid,void *buffer,uint32_t size);
/* Match the existing JIT guard: jailbreak libc hooks can hide CS_DEBUGGED.
 * Query read-only codesign metadata directly rather than that wrapper. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int kernel_csops(pid_t pid,unsigned int operation,void *buffer,size_t size) {
    return (int)syscall(SYS_csops,pid,operation,buffer,size);
}
#pragma clang diagnostic pop

typedef struct {
    HGGuestPeer identity;
    char path[4096];
} Snapshot;
static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3];
}
static int snapshot(pid_t pid,Snapshot *s) {
    memset(s,0,sizeof(*s));
    int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};
    struct kinfo_proc info;memset(&info,0,sizeof(info));size_t n=sizeof(info);
    uint32_t flags=0;
    if(sysctl(mib,4,&info,&n,NULL,0) || n!=sizeof(info) || info.kp_proc.p_pid!=pid ||
       info.kp_eproc.e_pcred.p_ruid!=info.kp_eproc.e_ucred.cr_uid ||
       info.kp_eproc.e_pcred.p_svuid!=info.kp_eproc.e_ucred.cr_uid ||
       info.kp_eproc.e_ucred.cr_uid==(uid_t)-1 ||
       !info.kp_proc.p_starttime.tv_sec || info.kp_proc.p_starttime.tv_usec<0 ||
       info.kp_proc.p_starttime.tv_usec>=1000000 ||
       proc_pidpath(pid,s->path,sizeof(s->path))<=0 || !memchr(s->path,0,sizeof(s->path)) || s->path[0]!='/' ||
       kernel_csops(pid,0,&flags,sizeof(flags)) || !(flags&(1u|0x10000000u)) ||
       kernel_csops(pid,5,s->identity.cdhash,sizeof(s->identity.cdhash)))return -1;
    s->identity.pid=pid;s->identity.uid=info.kp_eproc.e_ucred.cr_uid;
    s->identity.start_seconds=info.kp_proc.p_starttime.tv_sec;
    s->identity.start_microseconds=info.kp_proc.p_starttime.tv_usec;
    return 0;
}
static int entitlement(pid_t pid) {
    unsigned char header[8]={0};errno=0;
    int status=kernel_csops(pid,7,header,sizeof(header));
    uint32_t size=be32(header+4);
    if((status && errno!=ERANGE) || size<=8 || size>65536)return 0;
    NSMutableData *data=[NSMutableData dataWithLength:size];
    if(kernel_csops(pid,7,data.mutableBytes,size))return 0;
    const unsigned char *p=data.bytes;
    if(be32(p)!=0xfade7171 || be32(p+4)!=size)return 0;
    NSData *plist=[data subdataWithRange:NSMakeRange(8,size-8)];
    id object=[NSPropertyListSerialization propertyListWithData:plist options:NSPropertyListImmutable format:NULL error:NULL];
    if(![object isKindOfClass:NSDictionary.class])return 0;
    id value=object[@"com.apple.private.security.no-sandbox"];
    return value && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID() &&
        CFBooleanGetValue((__bridge CFBooleanRef)value);
}
static int same_peer(const HGGuestPeer *a,const HGGuestPeer *b) {
    return a->pid==b->pid && a->uid==b->uid && a->start_seconds==b->start_seconds &&
        a->start_microseconds==b->start_microseconds && !memcmp(a->cdhash,b->cdhash,20);
}
static int canonical_path(char *path) {
    char resolved[4096];
    if(!realpath(path,resolved))return -1;
    strcpy(path,resolved);return 0;
}
int hg_guest_peer_attest(int executable,HGGuestPeer *peer,const char **error) {
    if(!peer || !error)return -1;
    memset(peer,0,sizeof(*peer));*error="peer-parent-identity";
    @autoreleasepool {
        pid_t pid=getppid();Snapshot before,after;
        if(pid<=1 || snapshot(pid,&before))return -1;
        char expected[4096];memset(expected,0,sizeof(expected));
        if(fcntl(executable,F_GETPATH,expected) || !memchr(expected,0,sizeof(expected)) ||
           canonical_path(expected) || canonical_path(before.path) ||
           strcmp(expected,before.path)) { *error="peer-executable-path";return -1; }
        struct stat file,named;
        if(fstat(executable,&file) || lstat(before.path,&named) || !S_ISREG(named.st_mode) ||
           file.st_dev!=named.st_dev || file.st_ino!=named.st_ino) {
            *error="peer-executable-identity";return -1;
        }
        if(hg_guest_code_identity_matches(executable,before.identity.cdhash,error))return -1;
        *error="peer-no-sandbox-required";
        if(!entitlement(pid))return -1;
        *error="peer-parent-changed";
        if(getppid()!=pid || snapshot(pid,&after) || canonical_path(after.path) || !same_peer(&before.identity,&after.identity) ||
           strcmp(before.path,after.path) || !entitlement(pid) || getppid()!=pid ||
           fstat(executable,&named) || file.st_dev!=named.st_dev || file.st_ino!=named.st_ino ||
           file.st_size!=named.st_size || file.st_mtimespec.tv_sec!=named.st_mtimespec.tv_sec ||
           file.st_mtimespec.tv_nsec!=named.st_mtimespec.tv_nsec ||
           file.st_ctimespec.tv_sec!=named.st_ctimespec.tv_sec || file.st_ctimespec.tv_nsec!=named.st_ctimespec.tv_nsec ||
           lstat(expected,&named) || file.st_dev!=named.st_dev || file.st_ino!=named.st_ino)return -1;
        *peer=before.identity;peer->verified=1;*error=NULL;return 0;
    }
}
int hg_guest_peer_unchanged(int executable,const HGGuestPeer *peer,const char **error) {
    if(!error)return -1;
    *error="peer-not-verified";
    if(!peer || !peer->verified)return -1;
    HGGuestPeer current;
    if(hg_guest_peer_attest(executable,&current,error))return -1;
    if(!same_peer(peer,&current)){*error="peer-parent-changed";return -1;}
    *error=NULL;return 0;
}
