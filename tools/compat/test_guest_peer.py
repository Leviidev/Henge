"""Parent attestation policy with kernel-boundary stubs and a real denial.

Positive controls stub process metadata/entitlements, not iPad qualification.
The real control reaches the no-sandbox refusal for a signed ordinary parent.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin process/codesign controls')
class GuestPeerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='henge-peer-controls-')
        cls.addClassCleanup(cls.directory.cleanup)
        folder = Path(cls.directory.name)
        native = ROOT / 'compat/guest-provisioning'
        stub = folder / 'stub.m'
        stub.write_text(r'''
#import <Foundation/Foundation.h>
#include "HGGuestCodeIdentity.h"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/param.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <sys/syscall.h>
#include <unistd.h>
static char expected[4096];static const char *mode;static unsigned snapshots,parents,entitlements;
static int is(const char *s){return !strcmp(mode,s);}
static pid_t peer_ppid(void){parents++;return is("missing-parent") || (is("reparent") && parents>1)?1:4242;}
static int peer_sysctl(int *mib,u_int count,void *data,size_t *size,void *newp,size_t newsize) {
 if(count!=4 || mib[0]!=CTL_KERN || mib[1]!=KERN_PROC || mib[2]!=KERN_PROC_PID || mib[3]!=4242 || newp || newsize)abort();
 if(is("query-failed")){errno=EPERM;return -1;}
 struct kinfo_proc p={0};snapshots++;
 p.kp_proc.p_pid=4242;p.kp_proc.p_starttime.tv_sec=7+(is("start-changes") && snapshots>1);
 p.kp_eproc.e_ucred.cr_uid=501+(is("uid-changes") && snapshots>1);
 p.kp_eproc.e_pcred.p_ruid=p.kp_eproc.e_ucred.cr_uid;
 p.kp_eproc.e_pcred.p_svuid=p.kp_eproc.e_ucred.cr_uid+(is("mixed-creds")?1:0);
 if(*size!=sizeof(p))abort();memcpy(data,&p,sizeof(p));*size=is("short-info")?1:sizeof(p);return 0;
}
static int peer_pidpath(int pid,void *buffer,uint32_t size) {
 if(pid!=4242 || size<strlen(expected)+8)abort();
 strcpy(buffer,expected);if(is("wrong-path") || (is("exec-changes") && snapshots>1))strcat(buffer,".other");
 return (int)strlen(buffer);
}
static void put32(unsigned char *p,uint32_t v){p[0]=v>>24;p[1]=v>>16;p[2]=v>>8;p[3]=v;}
static long peer_syscall(long number,...) {
 va_list args;va_start(args,number);pid_t pid=va_arg(args,int);unsigned op=va_arg(args,unsigned);
 void *buffer=va_arg(args,void*);size_t size=va_arg(args,size_t);va_end(args);
 if(number!=SYS_csops || pid!=4242)abort();
 if(op==0){if(size!=4)abort();*(uint32_t*)buffer=is("invalid-signature")?0:is("debugged")?0x10000000u:1;return 0;}
 if(op==5){if(size!=20)abort();memset(buffer,is("hash-changes") && snapshots>1?'b':'a',20);return 0;}
 if(op!=7)abort();
 id value=@YES;
 if(is("integer-entitlement"))value=@1;
 if(is("string-entitlement"))value=@"true";
 if(is("false-entitlement") || (is("revoke-entitlement") && entitlements>=1))value=@NO;
 NSDictionary *dict=is("missing-entitlement")?@{}:@{@"com.apple.private.security.no-sandbox":value};
 NSData *xml=[NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
 uint32_t n=(uint32_t)xml.length+8;
 if(size==8){memset(buffer,0,8);put32((unsigned char*)buffer+4,is("oversize")?65537:n);errno=ERANGE;return -1;}
 if(is("entitlement-query-failed")){errno=EIO;return -1;}
 if(size!=n)abort();entitlements++;
 put32(buffer,is("bad-magic")?0:0xfade7171);put32((unsigned char*)buffer+4,n);
 memcpy((unsigned char*)buffer+8,xml.bytes,xml.length);return 0;
}
int hg_guest_code_identity_matches(int fd,const unsigned char hash[20],const char **error) {
 (void)hash;if(fd<0)abort();if(is("code-mismatch")){*error="test-code-mismatch";return -1;}*error=NULL;return 0;
}
#define sysctl peer_sysctl
#define proc_pidpath peer_pidpath
#define syscall peer_syscall
#define getppid peer_ppid
#include "HGGuestPeer.m"
int main(int n,char **v) {
 if(n!=3)return 64;mode=v[2];int fd=open(v[1],O_RDONLY|O_CLOEXEC);
 if(fd<0 || fcntl(fd,F_GETPATH,expected))return 65;
 HGGuestPeer peer;memset(&peer,0xff,sizeof(peer));const char *error=NULL;
 int result=hg_guest_peer_attest(fd,&peer,&error);
 int stable=!result && !hg_guest_peer_unchanged(fd,&peer,&error);
 printf("{\"passed\":%s,\"error\":\"%s\",\"verified\":%s,\"uid\":%u,\"pid\":%d,\"stable\":%s}\n",
 result?"false":"true",error?error:"",peer.verified?"true":"false",peer.uid,peer.pid,stable?"true":"false");
 close(fd);return result?1:0;
}
''')
        cls.control = folder / 'stub-control'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-fobjc-arc',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(native),
                        str(stub), '-framework', 'Foundation', '-o', str(cls.control)], check=True)
        cls.fixture = folder / 'expected'
        cls.fixture.write_bytes(b'authored expected-file metadata; code verifier is stubbed')
        child = folder / 'child.m'
        child.write_text(r'''
#include "HGGuestPeer.h"
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
int main(int n,char **v){if(n!=2)return 64;int fd=open(v[1],O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
HGGuestPeer peer;const char *error=NULL;int r=hg_guest_peer_attest(fd,&peer,&error);
printf("{\"passed\":%s,\"error\":\"%s\",\"verified\":%s,\"uid\":%u,\"pid\":%d}\n",
r?"false":"true",error?error:"",peer.verified?"true":"false",peer.uid,peer.pid);if(fd>=0)close(fd);return r?1:0;}
''')
        cls.real_child = folder / 'real-child'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-fobjc-arc',
                        '-I', str(native), str(child), str(native / 'HGGuestPeer.m'),
                        str(native / 'HGGuestCodeIdentity.c'), '-framework', 'Foundation',
                        '-o', str(cls.real_child)], check=True)
        parent = folder / 'parent.c'
        parent.write_text(r'''
#include <errno.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int n,char **v){if(n!=2)return 64;char path[4096];if(!realpath(v[0],path))return 65;
pid_t p=fork();if(p<0)return 66;if(!p){execl(v[1],v[1],path,NULL);_exit(67);}
int status;while(waitpid(p,&status,0)<0)if(errno!=EINTR)return 68;
return WIFEXITED(status)?WEXITSTATUS(status):69;}
''')
        cls.real_parent = folder / 'real-parent'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', str(parent),
                        '-o', str(cls.real_parent)], check=True)
        for binary in [cls.real_parent, cls.real_child]:
            subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(binary)],
                           check=True, capture_output=True)

    def run_control(self, mode, valid=False):
        r = subprocess.run([str(self.control), str(self.fixture), mode], capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0 if valid else 1, r.stdout + r.stderr)
        report = json.loads(r.stdout)
        self.assertEqual(report['passed'], valid)
        if valid:
            self.assertTrue(report['verified'] and report['stable'])
            self.assertEqual((report['uid'], report['pid']), (501, 4242))
        else:
            self.assertFalse(report['verified'])
            self.assertEqual((report['uid'], report['pid']), (0, 0))
        return report

    def test_consistent_parent_and_explicit_boolean_entitlement(self):
        self.run_control('normal', True)
        self.run_control('debugged', True)

    def test_no_missing_false_or_mistyped_no_sandbox(self):
        for mode in ['missing-entitlement', 'false-entitlement', 'integer-entitlement', 'string-entitlement']:
            with self.subTest(mode=mode):
                self.assertEqual(self.run_control(mode)['error'], 'peer-no-sandbox-required')

    def test_bad_or_unavailable_entitlement_blob(self):
        for mode in ['bad-magic', 'oversize', 'entitlement-query-failed']:
            with self.subTest(mode=mode):
                self.assertEqual(self.run_control(mode)['error'], 'peer-no-sandbox-required')

    def test_credentials_pid_start_exec_and_hash_changes_refused(self):
        for mode in ['uid-changes', 'start-changes', 'exec-changes', 'hash-changes', 'reparent', 'revoke-entitlement']:
            with self.subTest(mode=mode):
                self.assertEqual(self.run_control(mode)['error'], 'peer-parent-changed')

    def test_unqueryable_or_unqualified_parent_refused(self):
        for mode in ['query-failed', 'short-info', 'mixed-creds', 'missing-parent', 'invalid-signature']:
            with self.subTest(mode=mode):
                self.assertEqual(self.run_control(mode)['error'], 'peer-parent-identity')

    def test_wrong_main_executable_or_code_refused(self):
        self.assertEqual(self.run_control('wrong-path')['error'], 'peer-executable-path')
        self.assertEqual(self.run_control('code-mismatch')['error'], 'test-code-mismatch')

    def test_real_kernel_signed_parent_reaches_no_sandbox_refusal(self):
        r = subprocess.run([str(self.real_parent), str(self.real_child)], capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        report = json.loads(r.stdout)
        self.assertEqual(report['error'], 'peer-no-sandbox-required')
        self.assertFalse(report['verified'])
        self.assertEqual((report['uid'], report['pid']), (0, 0))


if __name__ == '__main__':
    unittest.main()
