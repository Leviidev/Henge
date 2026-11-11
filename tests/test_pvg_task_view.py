from pathlib import Path
import subprocess,tempfile,re
R=Path(__file__).resolve().parents[1];source=(R/'devices/pvg_lite.c').read_text()
def function(name):
 match=re.search(r'^[A-Za-z_][^\n;{]*\b'+name+r'\([^;\n]*\)\s*\{',source,re.M);assert match,name
 start=match.start();brace=source.index('{',match.start());depth=1;i=brace+1
 while depth:
  if source[i]=='{':depth+=1
  if source[i]=='}':depth-=1
  i+=1
 return source[start:i]+'\n'
names=['task_view_selected','hv_pvg_lite_use_task_view','hv_pvg_lite_task_view','task_tree','hv_pvg_lite_task_generation','task_ptr','task_read','hv_pvg_lite_task_read','hv_pvg_lite_task_page','hv_pvg_lite_task_pages','hv_pvg_lite_task_objects','hv_pvg_lite_compact_surfaces','hv_pvg_lite_surface']
body='''#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
typedef struct {uint32_t task,top,depth;uint64_t objects,generation;} HvPvgTaskView;
typedef struct {uint8_t mem[8*0x4000];} FakeMachine;
typedef struct {FakeMachine*m;uint32_t task_root[512];uint64_t task_objects[512],task_generation[512];uint64_t io_regs[8];} HvPvgLite;
static void*hv_phys_ptr(FakeMachine*m,uint64_t at,uint64_t len){return at+len<=sizeof m->mem?m->mem+at:NULL;}
static _Thread_local HvPvgLite *view_owner;static _Thread_local HvPvgTaskView worker_view;
#define OLD_DRIVER_OBJECTS 0x4000
'''+''.join(function(n)for n in names)+'''
static int thread_ok;static void*thread(void*arg){HvPvgLite*p=arg;thread_ok=hv_pvg_lite_task_generation(p,1)==22&&hv_pvg_lite_task_page(p,1,0x4000)==6;return NULL;}
#define C(x)do{checks++;if(!(x)){fprintf(stderr,"failed:%d\\n",__LINE__);return 1;}}while(0)
int main(){int checks=0;FakeMachine*m=calloc(1,sizeof *m);HvPvgLite p={.m=m};
 p.task_root[1]=1;p.task_generation[1]=11;((uint32_t*)(m->mem+0x4000))[0]=2;((uint32_t*)(m->mem+0x4000))[1]=1;((uint32_t*)(m->mem+2*0x4000))[1]=3;*(uint32_t*)(m->mem+3*0x4000)=0x1111;
 HvPvgTaskView v;C(!hv_pvg_lite_task_view(&p,1,&v));C(v.objects==0x4000&&v.generation==11);
 p.task_root[1]=4;p.task_generation[1]=22;p.task_objects[1]=0x8000;((uint32_t*)(m->mem+4*0x4000))[0]=5;((uint32_t*)(m->mem+4*0x4000))[1]=1;((uint32_t*)(m->mem+5*0x4000))[1]=6;*(uint32_t*)(m->mem+6*0x4000)=0x2222;
 /* The mapper's descriptor format is independent of task metadata. */
 p.io_regs[0x10 / 8]=0x400;
 *(uint32_t*)(m->mem+0x400)=5;
 C(hv_pvg_lite_compact_surfaces(&p));
 C(hv_pvg_lite_surface(&p,2)==m->mem+0x4400);
 hv_pvg_lite_use_task_view(&p,&v);uint32_t value=0,pages[1];C(hv_pvg_lite_task_generation(&p,1)==11);C(hv_pvg_lite_task_objects(&p,1)==0x4000);C(!hv_pvg_lite_task_read(&p,1,0x4000,&value,4)&&value==0x1111);C(hv_pvg_lite_task_page(&p,1,0x4000)==3);hv_pvg_lite_task_pages(&p,1,1,1,pages);C(pages[0]==3);
 C(hv_pvg_lite_compact_surfaces(&p));
 p.io_regs[0x30 / 8]=1;
 C(!hv_pvg_lite_compact_surfaces(&p));
 C(hv_pvg_lite_surface(&p,2)==m->mem+0x4800);
 pthread_t t;pthread_create(&t,NULL,thread,&p);pthread_join(t,NULL);C(thread_ok);C(hv_pvg_lite_task_generation(&p,1)==11);
 hv_pvg_lite_use_task_view(&p,NULL);C(hv_pvg_lite_task_generation(&p,1)==22);C(hv_pvg_lite_task_objects(&p,1)==0x8000);C(!hv_pvg_lite_task_read(&p,1,0x4000,&value,4)&&value==0x2222);free(m);printf("%d actual task-view/reuse/thread-isolation checks passed\\n",checks);}
'''
with tempfile.TemporaryDirectory()as t:
 p=Path(t);(p/'test.c').write_text(body);subprocess.run(['xcrun','--sdk','macosx','clang','-std=gnu11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'test.c'),'-o',str(p/'test')],check=True);subprocess.run([str(p/'test')],check=True)
