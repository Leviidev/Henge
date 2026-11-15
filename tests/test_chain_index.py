"""Run real chain insertion, invalidation and reset with platform helpers stubbed.
Native engine tests separately execute generated code. No timing speedup claim.
"""
from pathlib import Path
import subprocess,tempfile,os
root=Path(__file__).resolve().parents[1]
def function(file, signature):
 s=(root/file).read_text();a=s.index(signature);b=s.index('{',a);depth=1;e=b+1
 while depth:
  if s[e]=='{':depth+=1
  elif s[e]=='}':depth-=1
  e+=1
 return s[a:e]
preamble=r'''
#define _DEFAULT_SOURCE
#include "machine.h"
#include "mmu.h"
#include "reclaim_pages.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
__thread HvCpu *hv_self;
int hv_knob[HV_K_COUNT], hv_tlb_tmajor;
uint32_t *hv_smc_counts;
uint64_t *hv_smc_last, hv_smc_pages, hv_smc_cpu, hv_smc_dma;
/* This extracted index fixture never owns guest FP state. Native engine tests
   exercise the real assembly; accidentally reaching it here must fail. */
void hv_fp_leave(HvCpu *c){(void)c;abort();}
void hv_fp_enter(HvCpu *c){(void)c;abort();}
void hv_jit_write(HvJitRegion *r,uint32_t *p,const void *s,size_t n){(void)r;memcpy(p,s,n);}
void hv_jit_finish(HvJitRegion *r,uint32_t *p,size_t n){(void)r;(void)p;(void)n;}
void hv_jit_finish_branch(HvJitRegion *r,uint32_t *p){(void)r;(void)p;}
void hv_jit_reset(HvJitRegion *r){r->used=0;}
void hv_jit_ring(HvJitRegion *r,uint32_t n){(void)r;(void)n;}
void hv_jit_poison(HvJitRegion *r,uint32_t *p,size_t n){(void)r;(void)p;(void)n;abort();}
void hv_ijc_reset(HvCpu *c,int k){(void)c;(void)k;}
void hv_ijc_drop_code_page(HvCpu *c,uint64_t v){(void)c;(void)v;}
uint64_t hv_cpu_post_ijc_page(HvCpu *c,uint64_t v){(void)c;(void)v;return 0;}
void hv_ret_clear(HvCpu *c){(void)c;}
void hv_tlb_flush(HvCpu *c){(void)c;}
uint64_t hv_cpu_post(HvCpu *c,uint32_t f){(void)c;(void)f;return 0;}
void hv_machine_kick_all(HvMachine *m){(void)m;}
int hv_branch_retarget(uint32_t *i,int64_t off){(void)i;(void)off;return 0;}
'''
main=r'''
#define N 100000
#define PAGE (1ull << HV_TLB_PAGE_BITS)
static HvMachine m;
static uint8_t host[16384];
static uint32_t gen;
static uint8_t code_page;
static uint64_t ijc_note;
static uint64_t expected[N];
static void add(unsigned i,uint64_t pa){
 HvRam r={.pa=pa,.host=host,.page_gen=&gen};
 HvBlock b={.pa=pa,.va=0x40000000,.ram=&r,.gen=gen,.pg=0,.code=m.jit.base+2*N+i};
 m.slot_site[i]=m.jit.base+2*i;m.slot_stub[i]=m.slot_site[i]+1;
 m.slot_xa[i]=(uintptr_t)host-0x40000000ull;
 chain(&m,&m.slots[i],&b);expected[i]=pa|1;
}
static void drop(uint64_t pa){
 m.ram[0].pa=pa;code_page=1;
 unsigned before=m.nxchained,removed=0;
 hv_invalidate_code(&m,pa);
 for(unsigned i=0;i<N;i++){
  if(expected[i]==(pa|1)){expected[i]=0;removed++;assert(!m.slots[i]);assert(*m.slot_site[i]==0x14000001);}
  assert(m.slot_xpa[i]==expected[i]);
 }
 assert(m.nxchained==before-removed);
}
int main(void){
 pthread_mutex_init(&m.tr_mu,NULL);
 m.nram=1;m.ram[0]=(HvRam){.size=PAGE,.host=host,.code_pages=&code_page,.page_gen=&gen,.ijc_va=&ijc_note};
 m.jit.base=calloc(3*N,4);m.slots=calloc(N,8);
 m.slot_site=calloc(N,sizeof(void*));m.slot_stub=calloc(N,sizeof(void*));m.slot_cond=calloc(N,sizeof(void*));
 m.slot_xa=calloc(N,8);m.slot_xpa=calloc(N,8);m.xchained=calloc(N,4);
 uint64_t target=0x80000000, collision=target+PAGE;
 while(hv_xchain_bucket(collision)!=hv_xchain_bucket(target))collision+=PAGE;
 for(unsigned i=0;i<N;i++)add(i,i%1000==0?target:i%1000==1?collision:target+(i+1)*PAGE);
 assert(m.nxchained==N);
 /* Duplicate chain insertion is rejected, so lists cannot cycle. */
 add(0,target);assert(m.nxchained==N);
 drop(target);
 assert(m.xchain_examined<1000); /* collisions, not all 100,000 links */
 printf("chain index: first invalidation examined %llu of %u links\n",(unsigned long long)m.xchain_examined,N);
 drop(collision);drop(target+3*PAGE); /* remove head/middle/tail matches amid collisions */
 add(0,target);drop(target); /* removed slots may be linked again */
 hv_flush_blocks(&m);assert(!m.nxchained);
 for(unsigned i=0;i<HV_XCHAIN_BUCKETS;i++)assert(!m.xchain_heads[i]);
 memset(expected,0,sizeof expected);memset(m.slot_xpa,0,N*8); /* emitter resets reused slots */
 add(0,target);assert(m.nxchained==1);drop(target);assert(!m.nxchained);
 free(m.jit.base);free(m.slots);free(m.slot_site);free(m.slot_stub);free(m.slot_cond);free(m.slot_xa);free(m.slot_xpa);free(m.xchained);
 pthread_mutex_destroy(&m.tr_mu);
 puts("chain index: exact-page removal, hash collisions, duplicate rejection, branch repair, relink and cache reset passed");
}
'''
source=preamble+'\n'+function('host/jit_region.c','static size_t region_cap(')+'\n'+function('host/jit_region.c','size_t hv_jit_extent(')+'\n'+function('core/machine.c','HvRam *hv_ram_lookup(')+'\n'+function('core/machine.c','void hv_ijc_evict_index(')+'\n'+function('core/dispatch.c','static int poison_on(')+'\n'+function('core/dispatch.c','void hv_flush_blocks(')+'\n'+function('core/dispatch.c','static void chain(')+'\n'+function('core/machine.c','void hv_invalidate_code(')+main
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.c').write_text(source)
 subprocess.run([os.environ.get('CC','cc'),'-std=c11','-O1','-g','-fsanitize=address,undefined','-pthread','-I'+str(root/'core'),'-I'+str(root/'host'),str(p/'test.c'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=15)
