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
#include <time.h>
#include <unistd.h>
static NSString *scenario;
static int attached, launches, ejects, statusCode, inventoryCalls, timedWait, kills;
static int spawn_control(pid_t *pid, const char *path,
 const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attrs,
 char *const argv[], char *const env[]) {
 (void)actions;(void)attrs;
 if(strcmp(path,"/usr/sbin/hdik") || strcmp(env[1],"LC_ALL=C"))abort();
 launches++;*pid=123;statusCode=0;timedWait=0;
 if(!strcmp(argv[1],"-e")) {
  ejects++;
  if(strcmp(argv[2],"/dev/disk21"))abort();
  if([scenario isEqual:@"busy"] || ([scenario isEqual:@"retry"] && ejects<3))statusCode=1;
  else attached=0;
 } else {
  if(strcmp(argv[1],"-nomount") || strcmp(argv[2],"-drivekey") || strcmp(argv[3],"write-protected=true"))abort();
  attached=1;
  if([scenario isEqual:@"timeout"])timedWait=1;
  if([scenario isEqual:@"partial"])statusCode=1;
 }
 return 0;
}
static pid_t wait_control(pid_t pid,int *status,int options) {
 if(timedWait && options==WNOHANG)return 0;
 if(status)*status=statusCode<<8;return pid;
}
static int kill_control(pid_t pid,int signal) {
 if(pid!=123 || signal!=SIGKILL)abort();kills++;return 0;
}
static int sleep_control(const struct timespec *delay,struct timespec *remain) {
 (void)delay;(void)remain;return 0;
}
int hg_guest_media_copy(const HGGuestDisk *disk,char **json,const char **error) {
 inventoryCalls++;*error=NULL;
 if(!attached){*json=strdup("[]");return 0;}
 NSDictionary *row=@{@"content":@"GUID_partition_scheme",@"whole":@YES,
 @"writable":@([scenario isEqual:@"writable"]),@"bytes":@(disk->identity.st_size),
 @"bsd_name":@"disk21",@"registry_id":@(([scenario isEqual:@"reused"] && inventoryCalls>3)?999:101)};
 NSData *bytes=[NSJSONSerialization dataWithJSONObject:@[row] options:0 error:NULL];
 *json=strndup(bytes.bytes,bytes.length);return 0;
}
int hg_guest_media_copy_volume_group(const HGGuestDisk *disk,char **json,const char **error) {
 (void)disk;
 if([scenario isEqual:@"no-group"]){*error="unsupported-volume-group";return -1;}
 *json=strdup("{\"schema\":1}");*error=NULL;return 0;
}
#define posix_spawn spawn_control
#define waitpid wait_control
#define nanosleep sleep_control
#define kill kill_control
#include "HGGuestAttachment.m"
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=3)return 64;scenario=@(argv[2]);
 HGGuestDisk disk={.fd=open(argv[1],O_RDONLY|O_CLOEXEC)};
 if(disk.fd<0 || fstat(disk.fd,&disk.identity) || flock(disk.fd,LOCK_EX|LOCK_NB))return 70;
 attached=[scenario isEqual:@"existing"];
 HGGuestAttachment a={0};char *group=NULL;const char *error=NULL,*cleanup=NULL;
 int opened=hg_guest_attachment_open(&disk,&a,&group,&error);
 if([scenario isEqual:@"double-open"]) {
  char *second=NULL;const char *secondError=NULL;
  if(!hg_guest_attachment_open(&disk,&a,&second,&secondError) ||
     strcmp(secondError,"attachment-already-open"))abort();
 }
 if([scenario isEqual:@"reused"])inventoryCalls=4;
 int closed=a.disk?hg_guest_attachment_close(&a,&cleanup):0;
 printf("{\"opened\":%s,\"closed\":%s,\"attached\":%s,\"launches\":%d,\"ejects\":%d,\"kills\":%d,\"error\":\"%s\",\"cleanup\":\"%s\"}\n",
 opened?"false":"true",closed?"false":"true",attached?"true":"false",launches,ejects,kills,error?:"",cleanup?:"");
 free(group);hg_guest_disk_close(&disk);return 0;
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
