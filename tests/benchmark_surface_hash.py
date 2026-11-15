"""Report full-content scan cost; this is bandwidth work, not an energy measurement."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
source=r'''
#define _POSIX_C_SOURCE 200809L
#include "surface_hash.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec*1e-9; }
__attribute__((noinline)) static uint64_t scan(const uint8_t *p, size_t n) { return hv_surface_hash(p,n); }
int main(void) {
 for (unsigned mb=1;mb<=64;mb*=4) {
  size_t n=(size_t)mb<<20; uint8_t *p=calloc(1,n); if(!p)return 1;
  uint64_t sum=0; double begin=now(); unsigned repeats=256/mb;
  for(unsigned i=0;i<repeats;i++){ p[i%n]^=1; sum^=scan(p,n); }
  double seconds=now()-begin;
  printf("full-surface-hash: size=%uMiB ms/scan=%.3f GiB/s=%.3f signature=%llx\n",
   mb,seconds*1000/repeats,(double)n*repeats/seconds/(1ull<<30),(unsigned long long)sum);
  free(p);
 }
 return 0;
}'''
with tempfile.TemporaryDirectory() as tmp:
 c=Path(tmp)/'bench.c';c.write_text(source);exe=Path(tmp)/'bench'
 subprocess.run(['cc','-O3','-Wall','-Wextra','-Werror','-I'+str(root/'devices'),str(c),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
