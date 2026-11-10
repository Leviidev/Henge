from pathlib import Path
import re,subprocess,tempfile
R=Path(__file__).resolve().parents[1];s=(R/'devices/pvg_lite.c').read_text()
def function(name):
 m=re.search(r'^[A-Za-z_][^\n;{]*\b'+name+r'\([^;\n]*\)\s*\{',s,re.M);assert m;start=m.start();i=s.index('{',start)+1;depth=1
 while depth:
  if s[i]=='{':depth+=1
  if s[i]=='}':depth-=1
  i+=1
 return s[start:i]+'\n'
body='''#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct{uint8_t mem[256];}Machine;
typedef struct{Machine*m;void*metal,*gic;uint64_t io_regs[8],mapper_submitted;int mapper_pending,tally,iosfc_irq;}HvPvgLite;
static uint64_t sent[16];static unsigned count,irq,budget;
static void*hv_phys_ptr(Machine*m,uint64_t at,uint64_t n){return at+n<=sizeof m->mem?m->mem+at:NULL;}
static int hv_pvg_metal_reserve(void*m,uint32_t n){(void)m;(void)n;if(!budget)return 0;budget--;return 1;}
static void hv_pvg_metal_mapper(void*m,uint32_t op,uint32_t mapping,uint64_t index){(void)m;(void)op;(void)mapping;sent[count++]=index;}
static void hv_gicv3_pend(void*g,int n){(void)g;(void)n;irq++;}
'''+function('do_mapper')+function('hv_pvg_lite_mapper_complete')+'''
#define C(x)do{checks++;if(!(x)){fprintf(stderr,"failed:%d\\n",__LINE__);return 1;}}while(0)
int main(){unsigned checks=0;Machine m={0};HvPvgLite p={.m=&m,.metal=(void*)1};p.io_regs[0]=16;p.io_regs[1]=8;p.io_regs[3]=3;for(int i=0;i<3;i++){uint32_t*e=(uint32_t*)(m.mem+16+i*16);e[0]=i+1;e[1]=99;}
 budget=1;do_mapper(&p);C(count==1&&sent[0]==1);C(p.mapper_submitted==1);C(p.mapper_pending);C(p.io_regs[4]==0&&irq==0);
 budget=0;do_mapper(&p);C(count==1&&p.io_regs[4]==0);
 budget=2;do_mapper(&p);C(count==3&&sent[1]==2&&sent[2]==3);C(p.mapper_submitted==3&&!p.mapper_pending);C(p.io_regs[4]==0&&irq==0);
 do_mapper(&p);C(count==3);hv_pvg_lite_mapper_complete(&p,1);C(p.io_regs[4]==1&&irq==1);hv_pvg_lite_mapper_complete(&p,2);C(p.io_regs[4]==2&&irq==2);hv_pvg_lite_mapper_complete(&p,3);C(p.io_regs[4]==3&&irq==3);
 printf("%u actual mapper submitted/completed/backpressure checks passed\\n",checks);}
'''
with tempfile.TemporaryDirectory()as t:
 p=Path(t);(p/'test.c').write_text(body);subprocess.run(['xcrun','--sdk','macosx','clang','-std=gnu11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'test.c'),'-o',str(p/'test')],check=True);subprocess.run([str(p/'test')],check=True)
