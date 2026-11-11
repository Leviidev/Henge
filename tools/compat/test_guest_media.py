"""Native IOKit inventory controls with authored files and test-only IOKit stubs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'Native Foundation/stat controls')
class GuestMediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='henge-native-media-')
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        source = root / 'control.m'
        source.write_text(r'''
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>
static NSString *scenario, *path;
static unsigned int cursor, released;
static void *mock_open(const char *p,int f){(void)p;(void)f;return (void *)1;}
static int mock_close(void *p){(void)p;return 0;}
static CFMutableDictionaryRef matching(const char *p){(void)p;return CFDictionaryCreateMutable(NULL,0,NULL,NULL);}
static int services(unsigned int m,CFDictionaryRef d,unsigned int *i){(void)m;CFRelease(d);*i=9000;return [scenario isEqual:@"service-error"]?1:0;}
static unsigned int next(unsigned int i){(void)i;unsigned int count=[scenario hasPrefix:@"select"]?([scenario isEqual:@"select-duplicate"]?3:2):[scenario isEqual:@"limit"]?4097:[scenario isEqual:@"duplicate"]?2:1;return cursor<count?++cursor:0;}
static int release(unsigned int i){(void)i;released++;return 0;}
static int identifier(unsigned int e,uint64_t *v){*v=[scenario isEqual:@"zero-id"]?0:100+e;return 0;}
static CFTypeRef search(unsigned int e,const char *p,CFStringRef k,CFAllocatorRef a,unsigned int o){
 (void)e;(void)p;(void)k;(void)a;(void)o;
 if([scenario isEqual:@"no-ancestor"] || [scenario isEqual:@"limit"])return NULL;
 id value=path;
 if([scenario isEqual:@"unrelated"])value=[path stringByAppendingString:@".other"];
 if([scenario isEqual:@"alias"])value=[path stringByAppendingString:@".alias"];
 if([scenario isEqual:@"stale"])value=[path stringByAppendingString:@".missing"];
 if([scenario isEqual:@"relative"])value=@"relative/path";
 if([scenario isEqual:@"data-path"])value=[[path stringByAppendingString:@"\0"] dataUsingEncoding:NSUTF8StringEncoding];
 if([scenario isEqual:@"embedded-null"])value=[@"/bad\0/path" dataUsingEncoding:NSUTF8StringEncoding];
 return CFBridgingRetain(value);
}
static int properties(unsigned int e,CFMutableDictionaryRef *out,CFAllocatorRef a,unsigned int o){
 (void)e;(void)a;(void)o;
 NSMutableDictionary *p=[@{@"BSD Name":@"disk21s1",@"Content":@"41504653-0000-11AA-AA11-00306543ECAC",@"Size":@4096,@"Whole":@NO,@"Leaf":@YES,@"Writable":@NO} mutableCopy];
 if([scenario hasPrefix:@"select"]) {
 p[@"BSD Name"]=[NSString stringWithFormat:@"disk21s%u",e];
 p[@"RoleValue"]=e==1?@1:@64;
 p[@"UUID"]=[NSString stringWithFormat:@"12345678-1234-1234-1234-%012u",e];
 p[@"VolGroupUUID"]=([scenario isEqual:@"select-wrong-group"] && e==2)?@"ABCDEFAB-1234-1234-1234-123456789ABC":@"12345678-1234-1234-1234-123456789ABC";
 p[@"Encrypted"]=@NO;p[@"Locked"]=@NO;
 if([scenario isEqual:@"select-missing-lock"])[p removeObjectForKey:@"Locked"];
 if([scenario isEqual:@"select-encrypted"])p[@"Encrypted"]=@YES;
 if([scenario isEqual:@"select-locked"])p[@"Locked"]=@YES;
 if([scenario isEqual:@"select-roleless"])p[@"RoleValue"]=@0;
 if([scenario isEqual:@"select-combined-role"])p[@"RoleValue"]=@65;
 if([scenario isEqual:@"select-zero-group"])p[@"VolGroupUUID"]=@"00000000-0000-0000-0000-000000000000";
 if([scenario isEqual:@"select-missing-uuid"])[p removeObjectForKey:@"UUID"];
 if([scenario isEqual:@"select-same-uuid"])p[@"UUID"]=@"12345678-1234-1234-1234-123456789ABC";
 if([scenario isEqual:@"select-nonleaf"])p[@"Leaf"]=@NO;
 }
 if([scenario isEqual:@"metadata"]) {p[@"RoleValue"]=@64;p[@"UUID"]=@"12345678-1234-1234-1234-123456789ABC";p[@"VolGroupUUID"]=@"ABCDEFAB-1234-1234-1234-123456789ABC";p[@"Encrypted"]=@NO;p[@"Locked"]=@NO;}
 if([scenario isEqual:@"bad-role"])p[@"RoleValue"]=@YES;
 if([scenario isEqual:@"oversize-role"])p[@"RoleValue"]=@65536;
 if([scenario isEqual:@"bad-uuid"])p[@"UUID"]=@"invalid";
 if([scenario isEqual:@"bad-encrypted"])p[@"Encrypted"]=@1;
 if([scenario isEqual:@"bad-name"])p[@"BSD Name"]=@"disk21/../../other";
 if([scenario isEqual:@"bad-name-null"])p[@"BSD Name"]=@"disk21\0other";
 if([scenario isEqual:@"zero-size"])p[@"Size"]=@0;
 if([scenario isEqual:@"float-size"])p[@"Size"]=@4096.5;
 if([scenario isEqual:@"bool-size"])p[@"Size"]=@YES;
 if([scenario isEqual:@"wrong-bool"])p[@"Whole"]=@1;
 if([scenario isEqual:@"missing-content"])[p removeObjectForKey:@"Content"];
 *out=(CFMutableDictionaryRef)CFBridgingRetain(p);return [scenario isEqual:@"properties-error"]?1:0;
}
static void *mock_symbol(void *p,const char *n){(void)p;
 if([scenario isEqual:@"missing-symbol"])return NULL;
 #define SYMBOL(name,fn) if(!strcmp(n,name))return (void *)fn
 SYMBOL("IOServiceMatching",matching);SYMBOL("IOServiceGetMatchingServices",services);
 SYMBOL("IOIteratorNext",next);SYMBOL("IOObjectRelease",release);
 SYMBOL("IORegistryEntryCreateCFProperties",properties);SYMBOL("IORegistryEntrySearchCFProperty",search);
 SYMBOL("IORegistryEntryGetRegistryEntryID",identifier);return NULL;
}
#define dlopen mock_open
#define dlclose mock_close
#define dlsym mock_symbol
#include "HGGuestMedia.m"
int main(int n,char **v){@autoreleasepool{
 if(n!=3)return 64;path=@(v[1]);scenario=@(v[2]);
 HGGuestDisk d={.fd=open(v[1],O_RDONLY|O_CLOEXEC)};if(d.fd<0 || fstat(d.fd,&d.identity) || flock(d.fd,LOCK_EX|LOCK_NB))return 70;
 char *json=NULL;const char *error=NULL;int result=[scenario hasPrefix:@"select"]?hg_guest_media_copy_sonoma_data(&d,&json,&error):hg_guest_media_copy(&d,&json,&error);
 printf("{\"ok\":%s,\"media\":%s,\"released\":%u,\"error\":\"%s\"}\n",result?"false":"true",json?:"null",released,error?:"");
 free(json);hg_guest_disk_close(&d);return result?1:0;
}}
''')
        cls.control = root / 'control'
        native = ROOT / 'compat/guest-provisioning'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-fobjc-arc',
                        '-I', str(native), str(source), str(native / 'HGGuestDisk.c'),
                        '-framework', 'Foundation', '-lz', '-o', str(cls.control)], check=True)

    def setUp(self):
        self.files = tempfile.TemporaryDirectory(prefix='henge-media-fixture-')
        self.addCleanup(self.files.cleanup)
        self.path = Path(self.files.name) / 'owned.img'
        self.path.write_bytes(b'authored file for media identity')
        self.path.with_suffix('.img.other').write_bytes(b'different inode')
        os.link(self.path, self.path.with_suffix('.img.alias'))

    def run_control(self, scenario):
        result = subprocess.run([str(self.control), str(self.path), scenario], capture_output=True, timeout=5)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if report['ok'] else 1)
        return report

    def test_owned_inode_alias_and_data_path(self):
        for scenario in ('valid', 'alias', 'data-path'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertTrue(r['ok'])
                self.assertEqual(len(r['media']), 1)
                self.assertEqual(r['media'][0]['registry_id'], 101)
                self.assertEqual(r['released'], 2)
                self.assertFalse(r['media'][0]['writable'])

    def test_unique_volume_group_selection_and_refusal(self):
        r = self.run_control('select-valid')
        self.assertTrue(r['ok'])
        self.assertEqual(r['media']['system']['bsd_name'], 'disk21s1')
        self.assertEqual(r['media']['data']['bsd_name'], 'disk21s2')
        self.assertFalse(r['media']['volume_mounted'])
        for scenario in ('select-duplicate', 'select-wrong-group', 'select-missing-lock', 'select-encrypted',
                         'select-locked', 'select-roleless', 'select-combined-role',
                         'select-zero-group', 'select-missing-uuid', 'select-same-uuid', 'select-nonleaf'):
            with self.subTest(scenario=scenario):
                self.assertFalse(self.run_control(scenario)['ok'])

    def test_apfs_metadata_is_typed_and_missing_values_stay_missing(self):
        r = self.run_control('metadata')
        self.assertTrue(r['ok'])
        metadata = r['media'][0]['apfs_metadata']
        self.assertEqual(metadata['RoleValue'], 64)
        self.assertFalse(metadata['Encrypted'])
        self.assertFalse(metadata['Locked'])
        self.assertEqual(metadata['UUID'], '12345678-1234-1234-1234-123456789ABC')
        self.assertEqual(self.run_control('valid')['media'][0]['apfs_metadata'], {})
        for scenario in ('bad-role', 'oversize-role', 'bad-uuid', 'bad-encrypted'):
            self.assertFalse(self.run_control(scenario)['ok'])

    def test_unrelated_and_nonimage_media_do_not_grant_ownership(self):
        for scenario in ('unrelated', 'no-ancestor'):
            r = self.run_control(scenario)
            self.assertTrue(r['ok'])
            self.assertEqual(r['media'], [])
            self.assertEqual(r['released'], 2)

    def test_stale_or_malformed_ancestor_never_reports_empty_success(self):
        for scenario in ('stale', 'relative', 'embedded-null'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertFalse(r['ok'])
                self.assertIsNone(r['media'])
                self.assertEqual(r['released'], 2)

    def test_invalid_owned_properties_fail_with_iterator_cleanup(self):
        for scenario in ('zero-id', 'bad-name', 'bad-name-null', 'zero-size', 'float-size', 'bool-size',
                         'wrong-bool', 'missing-content', 'properties-error', 'duplicate'):
            with self.subTest(scenario=scenario):
                r = self.run_control(scenario)
                self.assertFalse(r['ok'])
                self.assertIsNone(r['media'])
                self.assertEqual(r['released'], 3 if scenario == 'duplicate' else 2)

    def test_enumeration_limits_and_missing_api_fail_closed(self):
        for scenario in ('missing-symbol', 'service-error', 'limit'):
            self.assertFalse(self.run_control(scenario)['ok'])


if __name__ == '__main__':
    unittest.main()
