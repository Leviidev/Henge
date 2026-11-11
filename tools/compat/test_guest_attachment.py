"""Native attachment state-machine controls; subprocess/IOKit boundaries mocked."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class GuestAttachmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='henge-attachment-tests-')
        cls.addClassCleanup(cls.directory.cleanup)
        base = Path(cls.directory.name)
        source = base / 'control.m'
        source.write_text(r'''
#import <Foundation/Foundation.h>
#include "HGGuestAttachment.h"
#include "HGGuestMedia.h"
#include <fcntl.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <time.h>
#include <unistd.h>
static NSString *scenario;
static int attached, launches, ejects, statusCode, inventoryCalls, timedWait, kills;
static char mountPaths[2][PATH_MAX];
static int mounted[2], unmounts;
static int spawn_control(pid_t *pid, const char *path,
 const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attrs,
 char *const argv[], char *const env[]) {
 (void)actions;(void)attrs;
 if(strcmp(env[1],"LC_ALL=C"))abort();
 launches++;*pid=123;statusCode=0;timedWait=0;
 if(!strcmp(path,"/sbin/mount_apfs")) {
  if(strcmp(argv[1],"-o") || strcmp(argv[2],"rdonly,nobrowse,noexec,nosuid"))abort();
  int index=!strcmp(argv[3],"/dev/disk21s2");
  strlcpy(mountPaths[index],argv[4],PATH_MAX);
  if(index && [scenario isEqual:@"mount-data-fail"])statusCode=1;
  else mounted[index]=1;
  if(!index && [scenario hasPrefix:@"version-"]) {
   NSString *core=[@(argv[4]) stringByAppendingPathComponent:@"System/Library/CoreServices"];
   [[NSFileManager defaultManager] createDirectoryAtPath:core withIntermediateDirectories:YES attributes:nil error:NULL];
   NSString *file=[core stringByAppendingPathComponent:@"SystemVersion.plist"];
   NSMutableDictionary *version=[@{@"ProductName":@"macOS",@"ProductVersion":@"14.6.1",@"ProductBuildVersion":@"23G93"} mutableCopy];
   if([scenario isEqual:@"version-sequoia"]){version[@"ProductVersion"]=@"15.0";version[@"ProductBuildVersion"]=@"24A335";}
   if([scenario isEqual:@"version-type"])version[@"ProductVersion"]=@14;
   if([scenario isEqual:@"version-newline"])version[@"ProductVersion"]=@"14.6.1\n";
   if([scenario isEqual:@"version-build"])version[@"ProductBuildVersion"]=@"23G93/other";
   if([scenario isEqual:@"version-name"])version[@"ProductName"]=@"iPadOS";
   NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:version
    format:[scenario isEqual:@"version-binary"]?NSPropertyListBinaryFormat_v1_0:NSPropertyListXMLFormat_v1_0
    options:0 error:NULL];
   if([scenario isEqual:@"version-oversize"])bytes=[NSMutableData dataWithLength:65537];
   if([scenario isEqual:@"version-link"])symlink("/etc/hosts",file.fileSystemRepresentation);
   else if(![scenario isEqual:@"version-missing"])[bytes writeToFile:file atomically:NO];
  }
  if([scenario isEqual:@"mount-unkillable"])timedWait=1;
  return 0;
 }
 if(strcmp(path,"/usr/sbin/hdik"))abort();
 if(!strcmp(argv[1],"-e")) {
  ejects++;
  if(strcmp(argv[2],"/dev/disk21"))abort();
  if([scenario isEqual:@"busy"] || ([scenario isEqual:@"retry"] && ejects<3))statusCode=1;
  else attached=0;
 } else {
  if(strcmp(argv[1],"-nomount") || strcmp(argv[2],"-drivekey") || strcmp(argv[3],"write-protected=true"))abort();
  attached=1;
  if([scenario isEqual:@"timeout"] || [scenario isEqual:@"unkillable"] ||
     [scenario isEqual:@"late-exit"])timedWait=1;
  if([scenario isEqual:@"partial"])statusCode=1;
 }
 return 0;
}
static pid_t wait_control(pid_t pid,int *status,int options) {
 if(timedWait && options==WNOHANG)return 0;
 if(status)*status=statusCode<<8;return pid;
}
static int kill_control(pid_t pid,int signal) {
 if(pid!=123 || signal!=SIGKILL)abort();kills++;
 if([scenario isEqual:@"timeout"])timedWait=0;
 return 0;
}
static int sleep_control(const struct timespec *delay,struct timespec *remain) {
 (void)delay;(void)remain;return 0;
}
static char *directory_control(char *path) {
 strcpy(path,"/tmp/henge-mount-test-XXXXXX");return mkdtemp(path);
}
static int filesystem_control(const char *path,struct statfs *fs) {
 memset(fs,0,sizeof(*fs));
 for(int i=0;i<2;i++)if(mounted[i] && !strcmp(path,mountPaths[i])) {
  strcpy(fs->f_fstypename,"apfs");strlcpy(fs->f_mntonname,path,sizeof(fs->f_mntonname));
  strcpy(fs->f_mntfromname,i?"/dev/disk21s2":"/dev/disk21s1");
  fs->f_flags=MNT_RDONLY|MNT_NOEXEC|MNT_NOSUID;
  if([scenario isEqual:@"mount-wrong-source"])strcpy(fs->f_mntfromname,"/dev/disk999");
  if([scenario isEqual:@"mount-writable"])fs->f_flags&=~MNT_RDONLY;
  return 0;
 }
 strcpy(fs->f_mntonname,"/");return 0;
}
static int unmount_control(const char *path,int flags) {
 if(flags)abort();
 for(int i=0;i<2;i++)if(mounted[i] && !strcmp(path,mountPaths[i])) {
  if([scenario hasPrefix:@"version-"])[[NSFileManager defaultManager]
   removeItemAtPath:[@(path) stringByAppendingPathComponent:@"System"] error:NULL];
  mounted[i]=0;unmounts++;return 0;
 }
 return -1;
}
static int descriptor_filesystem_control(int fd,struct statfs *fs) {
 char path[PATH_MAX];if(fcntl(fd,F_GETPATH,path))return -1;
 if(!strncmp(path,"/private/tmp/",13))memmove(path,path+8,strlen(path+8)+1);
 for(int i=0;i<2;i++)if(mountPaths[i][0] && !strncmp(path,mountPaths[i],strlen(mountPaths[i]))) {
  int result=filesystem_control(mountPaths[i],fs);
  if([scenario isEqual:@"version-crossfs"] && strcmp(path,mountPaths[i]))fs->f_fsid.val[0]=1;
  return result;
 }
 return -1;
}
int hg_guest_media_copy(const HGGuestDisk *disk,char **json,const char **error) {
 inventoryCalls++;*error=NULL;
 if(!attached){*json=strdup("[]");return 0;}
 NSDictionary *row=@{@"content":@"GUID_partition_scheme",@"whole":@YES,
 @"writable":@([scenario isEqual:@"writable"]),@"bytes":@(disk->identity.st_size),
 @"bsd_name":@"disk21",@"registry_id":@(([scenario isEqual:@"reused"] && inventoryCalls>3)?999:101)};
 NSMutableArray *rows=[NSMutableArray arrayWithObject:row];
 if([scenario hasPrefix:@"mount-"] || [scenario hasPrefix:@"version-"])for(int i=1;i<=2;i++)[rows addObject:@{
 @"bsd_name":[NSString stringWithFormat:@"disk21s%d",i],@"registry_id":@(101+i)}];
 NSData *bytes=[NSJSONSerialization dataWithJSONObject:rows options:0 error:NULL];
 *json=strndup(bytes.bytes,bytes.length);return 0;
}
int hg_guest_media_copy_volume_group(const HGGuestDisk *disk,char **json,const char **error) {
 (void)disk;
 if([scenario isEqual:@"no-group"]){*error="unsupported-volume-group";return -1;}
 *json=strdup("{\"system\":{\"bsd_name\":\"disk21s1\",\"registry_id\":102},\"data\":{\"bsd_name\":\"disk21s2\",\"registry_id\":103}}");*error=NULL;return 0;
}
#define posix_spawn spawn_control
#define waitpid wait_control
#define nanosleep sleep_control
#define kill kill_control
#define mkdtemp directory_control
#define statfs(path,fs) filesystem_control(path,fs)
#define unmount unmount_control
#define fstatfs(fd,fs) descriptor_filesystem_control(fd,fs)
#include "HGGuestAttachment.m"
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=3)return 64;scenario=@(argv[2]);
 HGGuestDisk disk={.fd=open(argv[1],O_RDONLY|O_CLOEXEC)};
 if(disk.fd<0 || fstat(disk.fd,&disk.identity) || flock(disk.fd,LOCK_EX|LOCK_NB))return 70;
 attached=[scenario isEqual:@"existing"];
 HGGuestAttachment a={0};char *group=NULL,*version=NULL;const char *error=NULL,*cleanup=NULL;
 int opened=hg_guest_attachment_open(&disk,&a,&group,&error);
 if(!opened && [scenario hasPrefix:@"mount-"])opened=hg_guest_attachment_mount_readonly(&a,&error);
 if(!opened && [scenario hasPrefix:@"version-"]) {
  opened=hg_guest_attachment_mount_readonly(&a,&error);
  if(!opened)opened=hg_guest_attachment_copy_system_version(&a,&version,&error);
 }
 if([scenario isEqual:@"late-exit"])timedWait=0;
 if([scenario isEqual:@"double-open"]) {
  char *second=NULL;const char *secondError=NULL;
  if(!hg_guest_attachment_open(&disk,&a,&second,&secondError) ||
     strcmp(secondError,"attachment-already-open"))abort();
 }
 if([scenario isEqual:@"reused"])inventoryCalls=4;
 int closed=a.disk?hg_guest_attachment_close(&a,&cleanup):0;
 printf("{\"opened\":%s,\"closed\":%s,\"attached\":%s,\"launches\":%d,\"ejects\":%d,\"kills\":%d,\"unmounts\":%d,\"version\":%s,\"error\":\"%s\",\"cleanup\":\"%s\"}\n",
 opened?"false":"true",closed?"false":"true",attached?"true":"false",launches,ejects,kills,unmounts,version?:"null",error?:"",cleanup?:"");
 for(int i=0;i<2;i++)if(mountPaths[i][0])rmdir(mountPaths[i]);
 free(group);free(version);hg_guest_disk_close(&disk);return 0;
}}
''')
        cls.control = base / 'control'
        native = ROOT / 'compat/guest-provisioning'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-I', str(native), str(source), str(native / 'HGGuestDisk.c'),
                        '-framework', 'Foundation', '-lz', '-o', str(cls.control)], check=True)

    def run_control(self, scenario):
        with tempfile.NamedTemporaryFile() as image:
            image.write(b'authored fixture identity')
            image.flush()
            r = subprocess.run([str(self.control), image.name, scenario],
                               capture_output=True, text=True, timeout=5, check=True)
        return json.loads(r.stdout)

    def test_success_holds_attachment_until_close(self):
        r = self.run_control('valid')
        self.assertTrue(r['opened'])
        self.assertTrue(r['closed'])
        self.assertFalse(r['attached'])
        self.assertEqual(r['ejects'], 1)

    def test_readonly_mounts_close_before_ejection(self):
        r = self.run_control('mount-valid')
        self.assertTrue(r['opened'])
        self.assertTrue(r['closed'])
        self.assertEqual(r['unmounts'], 2)
        self.assertEqual(r['ejects'], 1)

    def test_bounded_xml_and_binary_system_version_identity(self):
        for scenario in ('version-valid', 'version-binary'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertTrue(r['opened'])
                self.assertTrue(r['version']['sonoma'])
                self.assertEqual(r['version']['product_version'], '14.6.1')
                self.assertEqual(r['version']['product_build_version'], '23G93')
                self.assertTrue(r['closed'])
        r = self.run_control('version-sequoia')
        self.assertTrue(r['opened'])
        self.assertFalse(r['version']['sonoma'])

    def test_version_symlinks_cross_mounts_types_bounds_and_malformed_values_fail(self):
        for scenario in ('version-type', 'version-newline', 'version-build', 'version-name',
                         'version-oversize', 'version-link', 'version-missing', 'version-crossfs'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertFalse(r['opened'])
                self.assertIsNone(r['version'])
                self.assertTrue(r['closed'])

    def test_second_mount_failure_cleans_first_mount_and_empty_directory(self):
        r = self.run_control('mount-data-fail')
        self.assertFalse(r['opened'])
        self.assertTrue(r['closed'])
        self.assertEqual(r['unmounts'], 1)
        self.assertFalse(r['attached'])

    def test_unexpected_mount_identity_or_flags_prevent_unmount_and_eject(self):
        for scenario in ('mount-wrong-source', 'mount-writable'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertFalse(r['opened'])
                self.assertFalse(r['closed'])
                self.assertEqual(r['cleanup'], 'mount-cleanup-required')
                self.assertEqual(r['unmounts'], 0)
                self.assertEqual(r['ejects'], 0)

    def test_existing_attachment_is_never_ejected(self):
        r = self.run_control('existing')
        self.assertFalse(r['opened'])
        self.assertEqual(r['error'], 'image-already-attached')
        self.assertEqual(r['launches'], 0)
        self.assertTrue(r['attached'])

    def test_open_attachment_cannot_be_overwritten(self):
        r = self.run_control('double-open')
        self.assertTrue(r['opened'])
        self.assertTrue(r['closed'])
        self.assertEqual(r['launches'], 2)

    def test_partial_attach_and_selection_failure_cleanup(self):
        for scenario in ('partial', 'no-group'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertFalse(r['opened'])
                self.assertFalse(r['attached'])
                self.assertEqual(r['ejects'], 1)

    def test_timed_out_child_is_killed_reaped_and_owned_media_cleaned(self):
        r = self.run_control('timeout')
        self.assertFalse(r['opened'])
        self.assertFalse(r['attached'])
        self.assertEqual(r['kills'], 1)
        self.assertEqual(r['ejects'], 1)

    def test_unkillable_child_reports_pending_without_racing_cleanup(self):
        for scenario in ('unkillable', 'mount-unkillable'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertFalse(r['opened'])
                self.assertFalse(r['closed'])
                self.assertTrue(r['attached'])
                self.assertEqual(r['error'], 'attachment-command-still-running')
                self.assertEqual(r['cleanup'], 'attachment-command-still-running')
                self.assertEqual(r['kills'], 1)
                self.assertEqual(r['ejects'], 0)
                self.assertEqual(r['unmounts'], 0)

    def test_child_that_exits_later_can_be_reaped_before_cleanup(self):
        r = self.run_control('late-exit')
        self.assertFalse(r['opened'])
        self.assertTrue(r['closed'])
        self.assertFalse(r['attached'])
        self.assertEqual(r['ejects'], 1)

    def test_busy_ejection_retries_and_persistent_failure(self):
        r = self.run_control('retry')
        self.assertTrue(r['closed'])
        self.assertEqual(r['ejects'], 3)
        r = self.run_control('busy')
        self.assertFalse(r['closed'])
        self.assertTrue(r['attached'])
        self.assertEqual(r['cleanup'], 'attachment-cleanup-required')

    def test_reused_device_and_writable_media_never_grant_eject_authority(self):
        for scenario in ('reused', 'writable'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertFalse(r['closed'])
                self.assertEqual(r['ejects'], 0)
                self.assertEqual(r['cleanup'], 'attachment-cleanup-required')


if __name__ == '__main__':
    unittest.main()
