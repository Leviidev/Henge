/* Opt-in sampling only. Sampling perturbs the task: never treat this as power data. */
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "../core/machine.h"
#include "vm.h"
#include "scheduling.h"

extern void (*hv_prof_register)(void);
extern void (*hv_prof_session)(int);
extern void (*hv_prof_unregister)(void);
#define MAX_THREADS 16
#define SLOTS 4096
static pthread_mutex_t registry_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t registry_cv = PTHREAD_COND_INITIALIZER;
static pthread_key_t thread_key;
static thread_act_t threads[MAX_THREADS];
static int active, sampling;
static unsigned generation;
static struct { uintptr_t off; uint32_t n; } slots[SLOTS];
static uint64_t total, idle, jit, other_image, unknown;
static _Atomic uint64_t all_samples, all_dumps;
static uintptr_t image_base;
static _Atomic int words_on;

static int profiler_mode(void) {
    const char *mode = getenv("HV_PROF_IOS");
    return !mode || !strcmp(mode, "0") ? 0 : atoi(mode) >= 2 ? 2 : 1;
}

/* HV_PROF_IOS=2: the translated instruction under each JIT sample, by its encoding */
#define WORD_SLOTS 16384
static struct { uint32_t w, n; } words[WORD_SLOTS];
static uint64_t words_lost;

static void count_word(uint32_t w) {
    uint32_t h = (w * 2654435761u) % WORD_SLOTS;
    for (int k = 0; k < 64; k++, h = (h + 1) % WORD_SLOTS) {
        if (words[h].n && words[h].w == w) { words[h].n++; return; }
        if (!words[h].n) { words[h].w = w, words[h].n = 1; return; }
    }
    words_lost++;
}

static int by_word_count(const void *a,const void *b) {
    const __typeof__(words[0]) *x=a,*y=b;
    return x->n<y->n ? 1 : x->n>y->n ? -1 : 0;
}

static void dump_words(void) {
    // Keep actionable instruction samples in the two ordinary shared logs,
    // even when the separate bounded word file has filled. No raw user data.
    static __typeof__(words[0]) sorted_words[WORD_SLOTS];
    memcpy(sorted_words,words,sizeof words);
    qsort(sorted_words,WORD_SLOTS,sizeof sorted_words[0],by_word_count);
    for(int i=0;i<20 && sorted_words[i].n;i++)
        fprintf(stderr,"hvprof-jit-word: word=%08x samples=%u jit_share_pct=%.2f lost=%llu\n",
            sorted_words[i].w,sorted_words[i].n,jit?100.0*sorted_words[i].n/jit:0,(unsigned long long)words_lost);
    const char *home = getenv("HOME");
    char path[1024];
    snprintf(path, sizeof path, "%s/Documents/hvprof-words.txt", home ? home : ".");
    FILE *f = fopen(path, "a");
    if (f) fseek(f, 0, SEEK_END);
    if (f && ftell(f) >= (8 << 20)) { fclose(f); f = NULL; } /* bounded opt-in diagnostic file */
    if (f) {
        fprintf(f, "# dump at %ld pid %ld jit %llu lost %llu\n", (long)time(NULL), (long)getpid(), (unsigned long long)jit, (unsigned long long)words_lost);
        for (int i = 0; i < WORD_SLOTS; i++)
            if (words[i].n) fprintf(f, "p %u 0 %08x\n", words[i].n, words[i].w);
        fclose(f);
    }
    memset(words, 0, sizeof words);
    words_lost = 0;
}

static double monotonic(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}
static int bounded_env(const char *key,int fallback,int lo,int hi) {
    const char *p=getenv(key);if(!p)return fallback;
    char *end;long v=strtol(p,&end,10);
    return end==p || *end || v<lo || v>hi ? fallback : (int)v;
}
static void unregister_thread(void *value) {
    int i=(int)(uintptr_t)value-1;
    if(i<0 || i>=MAX_THREADS)return;
    pthread_mutex_lock(&registry_mu);
    thread_act_t port=threads[i];threads[i]=0;
    pthread_cond_broadcast(&registry_cv);
    pthread_mutex_unlock(&registry_mu);
    if(port)mach_port_deallocate(mach_task_self(),port);
}
static void reg(void) {
    if (!profiler_mode()) return;
    if(pthread_getspecific(thread_key))return;
    thread_act_t port=mach_thread_self();
    pthread_mutex_lock(&registry_mu);
    int i;for(i=0;i<MAX_THREADS && threads[i];i++){}
    int registered = 0;
    if(i<MAX_THREADS && pthread_setspecific(thread_key,(void *)(uintptr_t)(i+1))==0){threads[i]=port;registered=1;pthread_cond_broadcast(&registry_cv);}
    pthread_mutex_unlock(&registry_mu);
    if(!registered)mach_port_deallocate(mach_task_self(),port);
}
static void leave(void) {
    void *value = pthread_getspecific(thread_key);
    if (!value) return;
    pthread_setspecific(thread_key, NULL);
    unregister_thread(value);
}
static void session(int on) {
    int mode = profiler_mode();
    on = on && mode != 0;
    pthread_mutex_lock(&registry_mu);active=on;generation++;
    if (on) atomic_store(&words_on, mode >= 2);
    pthread_cond_broadcast(&registry_cv);
    while (!on && sampling) pthread_cond_wait(&registry_cv, &registry_mu);
    pthread_mutex_unlock(&registry_mu);
}
/* Functions in other images (the system's libraries), by the address dladdr names: where the rest goes */
#define OTHER_SLOTS 256
static struct { uintptr_t fn; const char *name; uint32_t n; } other[OTHER_SLOTS];

static void count_other(const Dl_info *info) {
    uintptr_t fn = (uintptr_t)info->dli_saddr;
    uint32_t h = (uint32_t)((fn >> 2) * 2654435761u) % OTHER_SLOTS;
    for (int k = 0; k < 16; k++, h = (h + 1) % OTHER_SLOTS) {
        if (other[h].n && other[h].fn == fn) { other[h].n++; return; }
        if (!other[h].n) { other[h].fn = fn, other[h].name = info->dli_sname, other[h].n = 1; return; }
    }
}

static void count_host(uintptr_t pc) {
    Dl_info info;
    if(!dladdr((void *)pc,&info)){other_image++;return;}
    if((uintptr_t)info.dli_fbase!=image_base){other_image++;count_other(&info);return;}
    uintptr_t off=pc-image_base;uint32_t h=(uint32_t)((off>>2)*2654435761u)%SLOTS;
    for(int k=0;k<64;k++,h=(h+1)%SLOTS){
        if(slots[h].n && slots[h].off==off){slots[h].n++;return;}
        if(!slots[h].n){slots[h].off=off;slots[h].n=1;return;}
    }
    unknown++;
}
static int by_count(const void *a,const void *b) {
    const __typeof__(slots[0]) *x=a,*y=b;
    return x->n<y->n ? 1 : x->n>y->n ? -1 : 0;
}
static int by_count_other(const void *a, const void *b) {
    const __typeof__(other[0]) *x = a, *y = b;
    return x->n < y->n ? 1 : x->n > y->n ? -1 : 0;
}
static void clear(void){memset(slots,0,sizeof slots);memset(other,0,sizeof other);total=idle=jit=other_image=unknown=0;}
static void dump(void) {
    static __typeof__(slots[0]) sorted[SLOTS];memcpy(sorted,slots,sizeof slots);qsort(sorted,SLOTS,sizeof sorted[0],by_count);
    uint64_t busy=total-idle;
    fprintf(stderr,"hvprof: %llu samples, idle %.1f%%, of busy: jit %.1f%%, other images %.1f%%, unknown=%llu base %#lx (sampling overhead; not energy)\n",
        (unsigned long long)total,total?100.0*idle/total:0,busy?100.0*jit/busy:0,busy?100.0*other_image/busy:0,(unsigned long long)unknown,(unsigned long)image_base);
    for(int i=0;i<40 && sorted[i].n;i++)fprintf(stderr,"hvprof: %5.2f%% +%#lx\n",busy?100.0*sorted[i].n/busy:0,(unsigned long)sorted[i].off);
    static __typeof__(other[0]) osorted[OTHER_SLOTS];
    memcpy(osorted, other, sizeof other);
    qsort(osorted, OTHER_SLOTS, sizeof osorted[0], by_count_other);
    for (int i = 0; i < 12 && osorted[i].n; i++)
        fprintf(stderr, "hvprof: %5.2f%% %s (other image)\n", busy ? 100.0 * osorted[i].n / busy : 0, osorted[i].name ? osorted[i].name : "?");
    if (words_on) dump_words();
    atomic_fetch_add(&all_dumps,1);clear();
}
static void *sampler(void *unused) {
    (void)unused;
    hv_schedule_aux_start(HV_ROLE_PROFILER);
    int hz=bounded_env("HV_PROF_IOS_HZ",100,1,1000), secs=bounded_env("HV_PROF_IOS_SECS",30,1,3600);
    int duration=bounded_env("HV_PROF_IOS_DURATION",0,0,86400);
    unsigned seen=0;double start=0,next_dump=0;
    fprintf(stderr,"hvprof: enabled hz=%d report_seconds=%d duration_seconds=%d; inactive sessions sleep\n",hz,secs,duration);
    for(;;){
        thread_act_t sample[MAX_THREADS];int n=0;
        pthread_mutex_lock(&registry_mu);
        while(!active || (duration && seen==generation && monotonic()-start>=duration)) {
            if (total) dump(); // include a partial/final window before sleeping
            pthread_cond_wait(&registry_cv,&registry_mu);
        }
        if(seen!=generation){seen=generation;start=monotonic();next_dump=start+secs;clear();}
        for(int i=0;i<MAX_THREADS;i++)if(threads[i] && mach_port_mod_refs(mach_task_self(),threads[i],MACH_PORT_RIGHT_SEND,1)==KERN_SUCCESS)sample[n++]=threads[i];
        sampling = 1;
        pthread_mutex_unlock(&registry_mu);
        HvMachine *m=hv_vm_machine();uintptr_t lo=m?(uintptr_t)m->jit.base:0,hi=m?lo+m->jit.capacity*4:0;
        for(int i=0;i<n;i++){
            thread_basic_info_data_t ti;mach_msg_type_number_t ni=THREAD_BASIC_INFO_COUNT;
            if(thread_info(sample[i],THREAD_BASIC_INFO,(thread_info_t)&ti,&ni)==KERN_SUCCESS){
                total++;atomic_fetch_add(&all_samples,1);
                if(ti.run_state!=TH_STATE_RUNNING)idle++;
                else {arm_thread_state64_t st;mach_msg_type_number_t sn=ARM_THREAD_STATE64_COUNT;
                    if(thread_get_state(sample[i],ARM_THREAD_STATE64,(thread_state_t)&st,&sn)!=KERN_SUCCESS)unknown++;
                    else {uintptr_t pc=(uintptr_t)arm_thread_state64_get_pc(st);if(pc>=lo && pc<hi){jit++;if(words_on && !(pc & 3) && hi-pc>=4)count_word(*(const volatile uint32_t *)(pc+(uintptr_t)m->jit.rw_diff));}else count_host(pc);}}
            }
            mach_port_deallocate(mach_task_self(),sample[i]);
        }
        double now=monotonic();if(now>=next_dump || (duration && now-start>=duration)){dump();next_dump=now+secs;}
        pthread_mutex_lock(&registry_mu);sampling=0;pthread_cond_broadcast(&registry_cv);pthread_mutex_unlock(&registry_mu);
        struct timespec nap={0,1000000000L/hz};nanosleep(&nap,NULL);
    }
    return NULL;
}
static void start_profiler(void) {
    words_on = atoi(getenv("HV_PROF_IOS")) >= 2;
    Dl_info info;if(dladdr((void *)start_profiler,&info))image_base=(uintptr_t)info.dli_fbase;
    if(pthread_key_create(&thread_key,unregister_thread)!=0)return;
    pthread_t t;
    if(pthread_create(&t,NULL,sampler,NULL)!=0){pthread_key_delete(thread_key);return;}
    pthread_detach(t);hv_prof_register=reg;hv_prof_session=session;hv_prof_unregister=leave;
    fprintf(stderr, "hengevm: profiler enabled: pid=%ld epoch=%ld words=%d (sampling adds overhead; word dumps are timestamped, not a speed benchmark)\n",
            (long)getpid(), (long)time(NULL), words_on);
}
void hv_prof_ios_start(void) {
    /* An earlier session with profiling off must not consume initialization.
       Native boot requests can overlap before the bridge acquires api_lock. */
    if(!profiler_mode()) {
        fprintf(stderr, "hengevm: profiler disabled for pid=%ld; existing hvprof-words.txt may belong to an earlier run\n", (long)getpid());
        return;
    }
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, start_profiler);
}
#ifdef HV_PROF_TEST
void hv_prof_test_counts(uint64_t *samples,uint64_t *dumps,unsigned *ports) {
    *samples=atomic_load(&all_samples);*dumps=atomic_load(&all_dumps);*ports=0;
    pthread_mutex_lock(&registry_mu);for(int i=0;i<MAX_THREADS;i++)*ports+=threads[i]!=0;pthread_mutex_unlock(&registry_mu);
}
#endif
