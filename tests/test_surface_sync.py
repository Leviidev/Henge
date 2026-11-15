"""Compile and execute the production per-batch surface scheduling helper."""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1];s=(root/'devices/pvg_metal.m').read_text()
a=s.index('static void sync_surface_once(');i=s.index('{',a)+1;level=1
while level:
 if s[i]=='{':level+=1
 if s[i]=='}':level-=1
 i+=1
source='''#include <stdint.h>
#include <assert.h>
#include <stdio.h>
typedef struct HvObject { void *iosurface; uint64_t sync_epoch; unsigned calls; } HvObject;
typedef struct HvReplay { uint64_t surface_checks, surface_checks_avoided; } HvReplay;
static void sync_iosurface(HvObject *s) { s->calls++; }
'''+s[a:i]+'''
int main(void) {
 HvReplay r={0};HvObject s={.iosurface=&r},alias={.iosurface=&r};
 for(int i=0;i<1000;i++)sync_surface_once(&r,&s,1);
 assert(s.calls==1 && r.surface_checks_avoided==999);
 sync_surface_once(&r,&alias,1);assert(alias.calls==1);
 sync_surface_once(&r,&s,2);assert(s.calls==2);
 sync_surface_once(&r,&s,0);sync_surface_once(&r,&s,0);assert(s.calls==4);
 sync_surface_once(&r,0,3);s.iosurface=0;sync_surface_once(&r,&s,3);assert(s.calls==4);
 puts("surface sync: 1000 repeated views -> 1 scan; distinct aliases, new batches, wrap and absent surfaces passed");
}
'''
b=root/'build';b.mkdir(exist_ok=True);p=b/'test_surface_sync.c';p.write_text(source)
subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p),'-o',str(b/'test_surface_sync')],check=True)
subprocess.run([str(b/'test_surface_sync')],check=True)
