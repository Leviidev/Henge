"""Native role-planning controls. Never mounts or writes an image."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GuestRoleTests(unittest.TestCase):
    def test_historical_and_new_checkpoints(self):
        with tempfile.TemporaryDirectory(prefix='henge-role-plan-') as tmp:
            source = Path(tmp) / 'control.c'
            source.write_text(r'''
#include "HGGuestRoles.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static HGGuestAPFSCatalog a,b;
static HGGuestRolePlan *p;
static const char *error;
static void reset(void) {
 memset(&a,0,sizeof(a));a.block_size=4096;a.checkpoint_count=3;
 a.latest_checkpoint_xid=3;a.record_count=3;
 for(unsigned i=0;i<3;i++) {
  HGGuestAPFSRecord *r=&a.records[i];
  r->volume.oid=i==2?10:10+i;r->volume.xid=i==2?1:3;
  r->volume.physical_block=100+i;r->volume.uuid[0]=i==2?1:i+1;
  r->volume.group_uuid[0]=5;r->volume.role=i==0?64:i==1?1:0;
  r->first_checkpoint_xid=i==2?1:3;r->last_checkpoint_xid=i==2?2:3;
 }
 b=a;p=NULL;error=NULL;
}
static void reject(int restore) {
 p=(void*)1;assert(hg_guest_roles_plan(&a,&b,restore,&p,&error)==-1);
 assert(!p && error);
}
int main(void) {
 reset();assert(!hg_guest_roles_plan(&a,&b,0,&p,&error));
 assert(p->count==2 && p->edits[0].target_role==0 && p->edits[1].target_role==0);
 assert(p->edits[0].expected.role==64 && b.records[0].volume.role==64);free(p);
 reset();b.records[0].volume.role=b.records[1].volume.role=0;
 assert(!hg_guest_roles_plan(&a,&b,1,&p,&error));
 assert(p->count==2 && p->edits[0].target_role==64 && p->edits[1].target_role==1);free(p);
 reset();assert(!hg_guest_roles_plan(&a,&b,1,&p,&error));assert(!p->count);free(p);
 /* New Data checkpoint inherits current role64, not historical role0. */
 reset();b.checkpoint_count=4;b.latest_checkpoint_xid=4;b.record_count=4;
 b.records[3]=b.records[0];b.records[3].volume.physical_block=200;
 b.records[3].volume.xid=4;b.records[3].volume.role=0;
 b.records[3].first_checkpoint_xid=b.records[3].last_checkpoint_xid=4;
 assert(!hg_guest_roles_plan(&a,&b,1,&p,&error));
 assert(p->count==1 && p->edits[0].target_role==64 && p->edits[0].expected.xid==4);free(p);
 b.records[3].volume.role=64;
 assert(!hg_guest_roles_plan(&a,&b,1,&p,&error));assert(!p->count);free(p);
 b.records[3].volume.role=1;reject(1);
 b.records[3].volume.uuid[0]=99;reject(1);
 reset();b.records[0].volume.group_uuid[0]=99;reject(1);
 reset();b.records[0].volume.role=2;reject(1);
 reset();b.records[0].volume.flags=1;reject(1);
 reset();b.records[1].volume.physical_block=100;reject(1);
 reset();b.records[1].volume.uuid[0]=1;reject(1);
 reset();b.records[0].volume.role=0;reject(0);
 reset();b.latest_checkpoint_xid=2;reject(1);
 reset();b.records[0].volume.xid=4;reject(1);
 reset();b.block_size=8192;reject(1);
 reset();b.record_count=HG_APFS_MAX_RECORDS+1;reject(1);
 reset();reject(2);
 puts("18 role-planning controls passed");return 0;
}
''')
            binary = Path(tmp) / 'control'
            native = ROOT / 'compat/guest-provisioning'
            subprocess.run(['clang', '-Wall', '-Wextra', '-Werror',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                            '-I', str(native), str(source), str(native / 'HGGuestRoles.c'),
                            '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
