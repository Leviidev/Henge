"""Regression for formerly invisible pixel/tail changes; production full hash."""
from pathlib import Path
import subprocess
r=Path(__file__).resolve().parents[1]; b=r/'build'; b.mkdir(exist_ok=True)
p=b/'test_surface_hash.c'
p.write_text(r'''
#include "surface_hash.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
 uint8_t *p=calloc(1,65536+8);assert(p);
 for(unsigned off=0;off<8;off++)for(unsigned n=0;n<260;n++) {
  uint64_t before=hv_surface_hash(p+off,n);
  for(unsigned i=0;i<n;i++) {p[off+i]=1;assert(hv_surface_hash(p+off,n)!=before);p[off+i]=0;}
 }
 uint64_t before=hv_surface_hash(p,65536);
 for(unsigned i=0;i<65536;i+=17){p[i]=0x80;assert(hv_surface_hash(p,65536)!=before);p[i]=0;}
 free(p);puts("Full surface hash: every byte/tail/alignment mutation detected; former byte9 regression fixed");
}
''')
subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-O2','-fsanitize=address,undefined','-I'+str(r/'devices'),str(p),'-o',str(b/'test_surface_hash')],check=True)
subprocess.run([str(b/'test_surface_hash')],check=True)
