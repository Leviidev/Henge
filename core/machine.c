#include "machine.h"

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sched.h>
#include <stdatomic.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mmu.h"
#include "fastmem.h"
#include "sysreg.h"
#include "translate.h"

extern void hv_exit(void);
extern void hv_helper_entry(void);
extern void hv_helper_thunk(void);
extern void hv_chain_thunk(void);
extern void hv_ijc_thunk(void);
extern void hv_xjump_thunk(void);

static int init_rest(HvMachine *m);

int hv_knob[HV_K_COUNT];
static const char *const hv_knob_names[HV_K_COUNT] = {"HV_NO_RAS", "HV_SUPERBLOCKS", "HV_GROUPS", "HV_WFI_SPIN", "HV_FLUSH", "HV_K1", "HV_K2", "HV_K3", "HV_TLBT", "HV_JIT_CAP", "HV_RECHECK", "HV_SYNC_WAIT", "HV_SWITCH_FLUSH", "HV_RANGE_DROP", "HV_MOVIMM", "HV_PREDSTAT", "HV_WALK_LOG", "HV_HOIST_CHECK", "HV_IJC_PAGES", "HV_DNS_PROXY", "HV_JIT_SEGMENTS", "HV_GROUP_MIN"};

static void knobs_init(void) {
    for (int i = 0; i < HV_K_COUNT; i++)
        hv_knob[i] = getenv(hv_knob_names[i]) ? atoi(getenv(hv_knob_names[i])) : 0;
    if (getenv("HV_NO_RAS") && !*getenv("HV_NO_RAS")) hv_knob[HV_K_NO_RAS] = 1;
    /* HV_SWITCH_FLUSH (skipping the local TLBI VMALLE1 xnu issues right after a process switch) is off unless asked
       since 2026-11-09: a checked skip on the phone found a kept user entry out of date (a stack page, no mapping),
       the stale state that flush exists to retire (xnu reusing a hardware ASID, which can leave every process's kept
       entries stale, not just the incoming one's). It was worth ~3% on a process-spawn loop; not worth guest memory. */
    if (!getenv("HV_GROUP_MIN")) hv_knob[HV_K_GROUP_MIN] = 2;
    if (!getenv("HV_IJC_PAGES")) hv_knob[HV_K_IJCPAGES] = 1;
    if (!getenv("HV_DNS_PROXY")) hv_knob[HV_K_DNSPROXY] = 1;
}

int hv_knob_set(HvMachine *m, const char *name, int value) {
    for (int i = 0; i < HV_K_COUNT; i++)
        if (!strcmp(name, hv_knob_names[i])) {
            hv_knob[i] = value;
            __atomic_store_n(&m->flush_pending, 1, __ATOMIC_SEQ_CST);
            hv_machine_kick_all(m);
            return 1;
        }
    return 0;
}

int hv_machine_init(HvMachine *m, size_t jit_bytes) {
    knobs_init();
    memset(m, 0, sizeof *m);
    if (hv_jit_region_open(&m->jit, jit_bytes) != 0) return -1;
    return init_rest(m);
}

int hv_machine_init_jit(HvMachine *m, void *rx, void *rw, size_t jit_bytes) {
    knobs_init();
    memset(m, 0, sizeof *m);
    if (hv_jit_region_attach(&m->jit, rx, rw, jit_bytes) != 0) return -1;
    return init_rest(m);
}

static int init_rest(HvMachine *m) {
    pthread_mutex_init(&m->big_mu, NULL);
    pthread_cond_init(&m->big_cv, NULL);
    pthread_mutexattr_t ra;
    pthread_mutexattr_init(&ra);
    pthread_mutexattr_settype(&ra, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&m->dev_mu, &ra);
    pthread_mutexattr_destroy(&ra);
    pthread_mutex_init(&m->tr_mu, NULL);
    pthread_mutex_init(&m->stw_mu, NULL);
    pthread_cond_init(&m->stw_cv, NULL);
    for (int i = 0; i < HV_MAX_CPUS; i++) {
        pthread_mutex_init(&m->percpu[i].wake_mu, NULL);
        pthread_cond_init(&m->percpu[i].wake_cv, NULL);
        pthread_mutex_init(&m->percpu[i].req_mu, NULL);
    }
    m->locks_initialized = 1;
    m->deadline_kicks_enabled = getenv("HV_DEADLINE_KICKS") && !strcmp(getenv("HV_DEADLINE_KICKS"), "1");
    m->wait_stats = getenv("HV_WAIT_STATS") && !strcmp(getenv("HV_WAIT_STATS"), "1");
    const char *tail = getenv("HV_JIT_TAIL");
    m->jit_tail_enabled = !tail || strcmp(tail, "0");
    m->fastmem_enabled = getenv("HV_FASTMEM") && atoi(getenv("HV_FASTMEM")) == 1;
    /* Paired native ARM64 tests retain the collision benefit without the
       cache-first hit-path tax. Expert A/B can still request lut-first. */
    const char *fm_order = getenv("HV_FASTMEM_ORDER");
    m->fastmem_tlb_first = !fm_order || strcmp(fm_order, "lut-first");
    m->fastmem_diagnostics = getenv("HV_FASTMEM_STATS") && atoi(getenv("HV_FASTMEM_STATS")) == 1;
    /* Native A/B was mixed, including split-alias regressions. Keep this
       correct but unproven scheduling experiment opt-in. */
    fprintf(stderr,"henge: checked writeback groups=%d (cached spans; whole-range guards and plain fallback retained)\n",hv_translate_writeback_groups());
    m->tlb_preload = getenv("HV_TLB_PRELOAD") && !strcmp(getenv("HV_TLB_PRELOAD"), "1");
    fprintf(stderr, "henge: memory-path: tlb-addend-preload=%d fastmem-cache=tagged-multiwindow (permissions and invalidations retained)\n", m->tlb_preload);
    fprintf(stderr, "henge: kernel read cache order=%s counters=%s\n",
            m->fastmem_tlb_first ? "tlb-first" : "lut-first",
            m->fastmem_tlb_first ? "TLB-miss probes only" : "eligible scalar loads");
    fprintf(stderr, "henge: kernel read cache requested=%s diagnostics=%s%s\n",
            m->fastmem_enabled ? "on" : "off", m->fastmem_diagnostics ? "on" : "off",
            m->fastmem_enabled && m->fastmem_diagnostics ? " (counting adds overhead; disable diagnostics for timing)" : "");
    /* The TLB layout (cpu.h): HV_TLBT from the environment here too, so the Mac tool and the tests can pick it. */
    hv_knob[HV_K_TLBT] = getenv("HV_TLBT") ? atoi(getenv("HV_TLBT")) : 1; /* table-major unless asked: 9-20% faster in 5 of 6 paired rounds of the mix */
    hv_tlb_tmajor = hv_knob[HV_K_TLBT] != 0;
    fprintf(stderr,"henge: memory-layout: table-major=%d register-group-min=%d (fixed-base checked ranges; reference threshold3 available)\n",hv_tlb_tmajor,hv_knob[HV_K_GROUP_MIN]>=3?3:2);
    /* HV_MOVIMM=1: constants built in registers instead of loaded from the pool (translate.c put_lit). Off: no
       measured gain (Mac mix 24.1 s either way, 2026-11-08); the tests pass with it on (HV_MOVIMM=1 make test). */
    hv_knob[HV_K_MOVIMM] = getenv("HV_MOVIMM") ? atoi(getenv("HV_MOVIMM")) : 0;
    /* On unless asked: the Mac bench (2026-11-08) posted 130-400 raced remote drops/s with it against 710-1370
       without (most walks a drop met were of other pages), and the phone's login storm waits up to 24% of a CPU. */
    hv_knob[HV_K_WALKLOG] = getenv("HV_WALK_LOG") ? atoi(getenv("HV_WALK_LOG")) : 1;
    if (getenv("HV_HOIST_CHECK")) hv_knob[HV_K_HOIST] = atoi(getenv("HV_HOIST_CHECK"));
    /* On unless asked: a code change used to drop every CPU's whole branch cache (~100/s with JavaScriptCore's JIT
       on the Mac bench, 300-390K refills/s after); now only the page's targets (Mac 2026-11-09: resets 195 -> 2/s,
       a JIT check of 200 recompiled functions correct; bench times the same within noise). */
    hv_knob[HV_K_IJCPAGES] = getenv("HV_IJC_PAGES") ? atoi(getenv("HV_IJC_PAGES")) : 1;
    hv_knob[HV_K_DNSPROXY] = getenv("HV_DNS_PROXY") ? atoi(getenv("HV_DNS_PROXY")) : 1;
    /* So the tests can run the translator these ways too (the iOS and --phone paths read them in knobs_init). */
    hv_knob[HV_K_SUPERBLOCKS] = getenv("HV_SUPERBLOCKS") ? atoi(getenv("HV_SUPERBLOCKS")) : 0;
    fprintf(stderr, "efficiency-v3: superblocks=%d (experimental) wait-probes=%d jit-finish=batched branch-patch=full-barrier (relaxed request falls back safely); indexed chain repair and full invalidation barriers retained\n", hv_knob[HV_K_SUPERBLOCKS] != 0, m->wait_stats);
    if (getenv("HV_JIT_SEGMENTS")) hv_knob[HV_K_JITSEGS] = atoi(getenv("HV_JIT_SEGMENTS"));
    /* The exact check for an access in a page's last 15 bytes, in the access's out-of-line path (code size only):
       on the phone, Golden Gate's boot and login send 80-240K such accesses a second to the helper without it. It
       costs ~13% of the code (Mac 2026-11-09: 296-300 against 259-261 bytes a block), and the phone's code cache
       fills every 40-60 s: worth a phone A/B (HV_RECHECK 0 vs 1 over a login), not a Mac one (~7K such accesses/s). */
    hv_knob[HV_K_RECHECK] = getenv("HV_RECHECK") ? atoi(getenv("HV_RECHECK")) : 1;
    fprintf(stderr, "henge: efficiency-v2: page-targeted-code-drops=%d walk-log=%d exact-page-end=%d; indexed chain repair retained; switch-flush=%d\n",
            hv_knob[HV_K_IJCPAGES], hv_knob[HV_K_WALKLOG], hv_knob[HV_K_RECHECK], hv_knob[HV_K_SWITCHFLUSH]);
    /* As many blocks as the region holds (a block is at least ~160 bytes of
       code), so the region filling, not this table, is what flushes; two
       chainable exits each at most. Untouched entries cost nothing. */
    size_t bytes = m->jit.capacity * sizeof(uint32_t);
    m->max_blocks = (uint32_t)(bytes / 160 < 4096 ? 4096 : bytes / 160);
    m->max_slots = m->max_blocks * 2;
    m->blocks = calloc(m->max_blocks, sizeof(HvBlock));
    m->jit_page_count=(bytes+16383)/16384;
    m->jit_page_heads=calloc(m->jit_page_count,sizeof *m->jit_page_heads);
    if (!m->blocks) return -1;
    m->stop_pc = ~0ull;
    m->stop_pc2 = ~0ull;
    m->chain = 1;
    /* A slot hint adds a dependent load and regressed changing-target calls in
       cloud comparisons. Keep it available for device A/B, not a default. */
    m->branch_site_hints=getenv("HV_BRANCH_SITE_HINTS")&&atoi(getenv("HV_BRANCH_SITE_HINTS"));
    /* Pairing can shorten a hit but adds a rehash on way1. Native paired
       comparisons did not establish a stable win; retain the normal default. */
    m->ijc_pair=getenv("HV_IJC_PAIR")&&atoi(getenv("HV_IJC_PAIR"));
    /* Fewer translations did not give a repeatable elapsed-time win in the
       mixed helper/cold-scan trial. Explicit reference=0 admits retention;
       ordinary launches retain FIFO without its activity instrumentation. */
    m->jit_retention=getenv("HV_JIT_RETAIN_REFERENCE")&&!atoi(getenv("HV_JIT_RETAIN_REFERENCE"));
    fprintf(stderr,"henge: engine-paths: interleaved-groups=%d paired-ijc=%d site-hints=%d recent-use-retention=%d (checked guards, cache authority and global eviction barriers retained)\n",
            hv_knob[HV_K_GROUPS]==2&&hv_translate_interleaved_groups(),m->ijc_pair,m->branch_site_hints,m->jit_retention);
    m->slots = calloc(m->max_slots, sizeof *m->slots);
    m->slot_site = calloc(m->max_slots, sizeof *m->slot_site);
    m->slot_stub = calloc(m->max_slots, sizeof *m->slot_stub);
    m->slot_cond = calloc(m->max_slots, sizeof *m->slot_cond);
    m->slot_xa = calloc(m->max_slots, sizeof *m->slot_xa);
    m->slot_xpa = calloc(m->max_slots, sizeof *m->slot_xpa);
    m->xchained = calloc(m->max_slots, sizeof *m->xchained);
    if (!m->slots || !m->slot_site || !m->slot_stub || !m->slot_cond || !m->slot_xa || !m->slot_xpa || !m->xchained) return -1;
    m->quiesce_initialized=hv_quiesce_init(&m->quiesce)==0;
    m->quiesce_enabled=m->quiesce_initialized && (!getenv("HV_STW_WAIT") || strcmp(getenv("HV_STW_WAIT"),"0"));
    fprintf(stderr,"henge: flush-wait: mode=%s; short spin then event wake, own requests serviced, 100us missed-wake fallback; guest WFE/timers unchanged\n",m->quiesce_enabled?"event":"legacy-yield");
    m->slot_free = calloc(m->max_slots, sizeof *m->slot_free);
    if (!m->slot_free) return -1;
    hv_jit_ring(&m->jit, hv_knob[HV_K_JITSEGS] ? (uint32_t)hv_knob[HV_K_JITSEGS] : 8);
    for (int i = 0; i < HV_MAX_CPUS; i++) { /* untouched pages cost nothing, so every CPU gets its tables now */
        HvPerCpu *p = &m->percpu[i];
        p->ijc = calloc(HV_IJC_TABLES * HV_IJC_TABLE_BYTES / 8, 8);
        p->ucode = calloc(1u << HV_UCODE_BITS, 8);
        p->cid_chunks = calloc(65536, sizeof *p->cid_chunks);
        if (!p->ijc || !p->ucode || !p->cid_chunks) return -1;
        for (int k = 0; k < HV_STASHES; k++) {
            p->stash[k].slot = calloc(HV_STASH_CAP, sizeof *p->stash[k].slot);
            p->stash[k].ent = calloc(HV_STASH_CAP, sizeof *p->stash[k].ent);
            if (!p->stash[k].slot || !p->stash[k].ent) return -1;
        }
    }
    return 0;
}

__thread HvCpu *hv_self;

void hv_dev_lock(HvMachine *m) {
    if (pthread_mutex_trylock(&m->dev_mu) == 0) return;
    uint64_t t0 = m->stats_interval ? mach_absolute_time() : 0;
    pthread_mutex_lock(&m->dev_mu);
    if (m->stats_interval) {
        m->stats.dev_waits++;
        m->stats.dev_wait_ticks += mach_absolute_time() - t0;
    }
}

void hv_dev_unlock(HvMachine *m) {
    pthread_mutex_unlock(&m->dev_mu);
}

static uint64_t post_locked_done(HvCpu *target, HvPerCpu *p) {
    uint64_t seq = __atomic_add_fetch(&p->req_seq, 1, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&p->req_mu);
    __atomic_store_n(&target->exit_req, 1, __ATOMIC_SEQ_CST);
    __asm__ volatile("sev" ::: "memory"); /* a WFE waiting in place (wfe() in dispatch.c) sees it now */
    hv_quiesce_notify(&target->m->quiesce); /* peer waiting for us must service this request */
    if (target->m->stats_interval) target->m->stats.kick_src[0]++;
    return seq;
}

uint64_t hv_cpu_post_tlbi(HvCpu *target, uint32_t op1, uint32_t crn, uint32_t crm, uint32_t op2, uint64_t xt) {
    HvPerCpu *p = target->pc_state;
    pthread_mutex_lock(&p->req_mu);
    if (p->nreq < sizeof p->req / sizeof p->req[0]) {
        p->req[p->nreq].op1 = op1, p->req[p->nreq].crn = crn, p->req[p->nreq].crm = crm, p->req[p->nreq].op2 = op2;
        p->req[p->nreq].xt = xt;
        p->nreq++;
    } else {
        p->req_flags |= HV_REQ_TLB_ALL; /* too many queued: drop everything instead */
    }
    return post_locked_done(target, p);
}

/* Code changed in a page whose blocks were cached as branch targets at VA page v (| 2), or v = 1: only the return
   predictions. Too many queued: the whole branch cache instead. */
uint64_t hv_cpu_post_ijc_page(HvCpu *target, uint64_t v) {
    HvPerCpu *p = target->pc_state;
    pthread_mutex_lock(&p->req_mu);
    if (p->nijc_page < sizeof p->ijc_page / sizeof p->ijc_page[0]) p->ijc_page[p->nijc_page++] = v;
    else p->req_flags |= HV_REQ_IJC_RESET;
    return post_locked_done(target, p);
}

uint64_t hv_cpu_post(HvCpu *target, uint32_t flags) {
    HvPerCpu *p = target->pc_state;
    pthread_mutex_lock(&p->req_mu);
    p->req_flags |= flags;
    return post_locked_done(target, p);
}

/* HV_SYNC_WAIT: a CPU waiting for another's acknowledgement sleeps (after a short spin) instead of
   spinning and yielding, so a host core is free for the CPU it waits on: the phone has two fast cores
   for three guest CPUs, the display and the app. The kernel's compare-and-wait on a 32-bit word. */
extern int __ulock_wait(uint32_t operation, void *addr, uint64_t value, uint32_t timeout_us);
extern int __ulock_wake(uint32_t operation, void *addr, uint64_t wake_value);
#define HV_UL_COMPARE_AND_WAIT 1u
#define HV_ULF_WAKE_ALL 0x100u
#define HV_ULF_NO_ERRNO 0x1000000u

/* The wait value must change for BOTH an acknowledgement and a parked peer.
   Waking ack_seq alone loses a park notification if the wake precedes the
   kernel wait: ack_seq did not change, so that wait can still go to sleep. */
static void ack_wake(HvPerCpu *p) {
    if (__atomic_load_n(&p->ack_waiters, __ATOMIC_SEQ_CST)) {
        __atomic_add_fetch(&p->ack_event, 1, __ATOMIC_SEQ_CST);
        __ulock_wake(HV_UL_COMPARE_AND_WAIT | HV_ULF_WAKE_ALL | HV_ULF_NO_ERRNO, &p->ack_event, 0);
    }
}

void hv_cpu_ack_wake(HvCpu *cpu) {
    if (cpu->pc_state) ack_wake(cpu->pc_state);
}

void hv_cpu_process_requests(HvCpu *cpu) {
    HvPerCpu *p = cpu->pc_state;
    uint64_t seq = __atomic_load_n(&p->req_seq, __ATOMIC_ACQUIRE);
    if (seq == __atomic_load_n(&p->ack_seq, __ATOMIC_RELAXED)) return;
    static __thread struct { uint32_t op1, crn, crm, op2; uint64_t xt; } q[64];
    static __thread uint64_t pages[16];
    pthread_mutex_lock(&p->req_mu);
    seq = p->req_seq;
    uint32_t flags = p->req_flags, n = p->nreq, npages = p->nijc_page;
    memcpy(q, p->req, n * sizeof q[0]);
    memcpy(pages, p->ijc_page, npages * sizeof pages[0]);
    p->req_flags = 0;
    p->nreq = 0;
    p->nijc_page = 0;
    pthread_mutex_unlock(&p->req_mu);
    if (flags & HV_REQ_TLB_ALL) {
        cpu->m->stats.flush_why[7]++;
        hv_tlb_flush(cpu);
    } else {
        for (uint32_t i = 0; i < n; i++) hv_tlbi_apply(cpu, q[i].op1, q[i].crn, q[i].crm, q[i].op2, q[i].xt);
    }
    if (flags & HV_REQ_IJC_RESET) {
        hv_ijc_reset(cpu, 0);
        hv_ijc_reset(cpu, 1);
    } else {
        for (uint32_t i = 0; i < npages; i++) hv_ijc_drop_code_page(cpu, pages[i]);
    }
    __atomic_store_n(&p->ack_seq, seq, __ATOMIC_RELEASE);
    ack_wake(p);
}

void hv_cpu_sync(HvCpu *self, HvCpu *target, uint64_t seq) {
    HvPerCpu *t = target->pc_state, *s = self ? self->pc_state : NULL;
    /* A completed release-published acknowledgement needs no parked/live
       transition and no wake of CPUs waiting on us. Own invalidations must
       still be serviced before returning to the caller. */
    if (__atomic_load_n(&t->ack_seq, __ATOMIC_ACQUIRE) >= seq) {
        if (self) hv_cpu_process_requests(self);
        return;
    }
    HvMachine *mm = target->m;
    uint64_t t0 = mm->stats_interval ? mach_absolute_time() : 0;
    if (s) {
        __atomic_store_n(&s->tlb_live, 0, __ATOMIC_SEQ_CST); /* others need not wait for this one meanwhile */
        ack_wake(s);
    }
    int sleep = hv_knob[HV_K_SYNCWAIT], probed = !t0 || !mm->wait_stats, probed_long = !t0 || !mm->wait_stats;
    if (s && mm->wait_stats) __atomic_store_n(&s->phase, HV_PHASE_SYNC, __ATOMIC_RELAXED);
    for (uint32_t spins = 0;; spins++) {
        uint32_t event = __atomic_load_n(&t->ack_event, __ATOMIC_SEQ_CST);
        uint64_t ack = __atomic_load_n(&t->ack_seq, __ATOMIC_ACQUIRE);
        if (ack >= seq) break;
        if (!probed && !(spins & 63) && mach_absolute_time() - t0 >= 2400) { /* 100 us: what is it doing? */
            probed = 1;
            thread_basic_info_data_t ti;
            mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
            uint32_t thread = __atomic_load_n(&t->thread, __ATOMIC_ACQUIRE);
            int on = !thread || (thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&ti, &cnt) == KERN_SUCCESS && ti.run_state == TH_STATE_RUNNING);
            mm->stats.sync_probe[on ? 1 : 0]++;
            if (__atomic_load_n(&t->walk_seq, __ATOMIC_RELAXED) & 1) mm->stats.sync_probe[2]++;
            if (__atomic_load_n(&t->ijc_seq, __ATOMIC_RELAXED) & 1) mm->stats.sync_probe[3]++;
        }
        if (probed && !probed_long && !(spins & 63) && mach_absolute_time() - t0 >= 24000) { /* 1 ms */
            probed_long = 1;
            thread_basic_info_data_t ti;
            mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
            uint32_t thread = __atomic_load_n(&t->thread, __ATOMIC_ACQUIRE);
            int on = !thread || (thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&ti, &cnt) == KERN_SUCCESS && ti.run_state == TH_STATE_RUNNING);
            mm->stats.sync_phase[on ? __atomic_load_n(&t->phase, __ATOMIC_RELAXED) % 5 : 5]++;
        }
        if (!__atomic_load_n(&t->tlb_live, __ATOMIC_SEQ_CST)) break; /* parked: it does the work before it runs again */
        if (self) hv_cpu_process_requests(self);
        if (sleep && spins >= 64) {
            __atomic_add_fetch(&t->ack_waiters, 1, __ATOMIC_SEQ_CST);
            /* Arm before rechecking the predicates. A notification between
               this check and kernel entry changes event, preventing sleep.
               The 100us fallback still bounds own-request service latency. */
            if (__atomic_load_n(&t->ack_seq, __ATOMIC_SEQ_CST) == ack && __atomic_load_n(&t->tlb_live, __ATOMIC_SEQ_CST)) {
                if (s) __atomic_add_fetch(&s->sync_sleeps, 1, __ATOMIC_RELAXED);
                int rc = __ulock_wait(HV_UL_COMPARE_AND_WAIT | HV_ULF_NO_ERRNO, &t->ack_event, event, 100);
                if (rc == -ETIMEDOUT && s) __atomic_add_fetch(&s->sync_timeouts, 1, __ATOMIC_RELAXED);
                if (rc < 0 && rc != -ETIMEDOUT && rc != -EINTR) {
                    if (s) __atomic_add_fetch(&s->sync_errors, 1, __ATOMIC_RELAXED);
                    sched_yield(); /* an unavailable wait facility must not become a tight spin */
                }
            }
            __atomic_sub_fetch(&t->ack_waiters, 1, __ATOMIC_SEQ_CST);
        } else if (spins > 200) {
            sched_yield();
        }
    }
    if (s) {
        __atomic_store_n(&s->tlb_live, 1, __ATOMIC_SEQ_CST);
        hv_cpu_process_requests(self); /* anything that came in while we were not live */
        if (mm->wait_stats) __atomic_store_n(&s->phase, HV_PHASE_HELPER, __ATOMIC_RELAXED); /* TLBIs are waited for from a helper */
    }
    if (mm->stats_interval) {
        uint64_t dt = mach_absolute_time() - t0;
        int b = dt < 240 ? 0 : dt < 2400 ? 1 : dt < 24000 ? 2 : 3; /* 24 MHz ticks */
        mm->stats.syncs++;
        mm->stats.sync_ticks += dt;
        mm->stats.sync_len[b]++;
        mm->stats.sync_len_ticks[b] += dt;
    }
}

void hv_big_lock(HvMachine *m) {
    if (!m->big_lock_on) return;
    pthread_mutex_lock(&m->big_mu);
    uint64_t me = m->big_next++;
    while (m->big_serving != me) pthread_cond_wait(&m->big_cv, &m->big_mu);
    pthread_mutex_unlock(&m->big_mu);
}

void hv_big_unlock(HvMachine *m) {
    if (!m->big_lock_on) return;
    pthread_mutex_lock(&m->big_mu);
    m->big_serving++;
    pthread_cond_broadcast(&m->big_cv);
    pthread_mutex_unlock(&m->big_mu);
}

void hv_big_yield(HvMachine *m) {
    if (!m->big_lock_on) return;
    pthread_mutex_lock(&m->big_mu);
    int waiting = m->big_next - m->big_serving > 1;
    pthread_mutex_unlock(&m->big_mu);
    if (!waiting) return;
    hv_big_unlock(m);
    hv_big_lock(m);
}

/* Make cpu leave its block at its next checked exit (and end an in-place WFE wait). */
void hv_cpu_kick(HvCpu *cpu) {
    __atomic_store_n(&cpu->exit_req, 1, __ATOMIC_SEQ_CST);
    __asm__ volatile("sev" ::: "memory");
}

/* Return tables: nothing to return to. A tag is never 0: salts are not, and no VA has their bits. */
void hv_ret_clear(HvCpu *cpu) {
    memset(cpu->ret_tab, 0, sizeof cpu->ret_tab);
    cpu->ret_salt[0] = cpu->ret_salt[1] = 1ull << 48;
}

void hv_cpu_wake(HvCpu *cpu) {
    __atomic_store_n(&cpu->exit_req, 1, __ATOMIC_SEQ_CST);
    __asm__ volatile("sev" ::: "memory");
    if (cpu->m->stats_interval) cpu->m->stats.kick_src[1]++;
    HvPerCpu *p = cpu->pc_state;
    pthread_mutex_lock(&p->wake_mu);
    p->wake_pending = 1;
    pthread_cond_signal(&p->wake_cv);
    pthread_mutex_unlock(&p->wake_mu);
}

void hv_machine_kick_all(HvMachine *m) {
    if (m->stats_interval) m->stats.kick_src[2]++;
    for (int i = 0; i < m->ncpus; i++)
        if (m->cpus[i]) __atomic_store_n(&m->cpus[i]->exit_req, 1, __ATOMIC_SEQ_CST);
    __asm__ volatile("sev" ::: "memory");
}

unsigned hv_machine_kick_active(HvMachine *m) {
    unsigned marked = 0;
    for (int i = 0; i < m->ncpus; i++) {
        if (m->cpus[i] && __atomic_load_n(&m->percpu[i].active, __ATOMIC_SEQ_CST)) {
            __atomic_store_n(&m->cpus[i]->exit_req, 1, __ATOMIC_SEQ_CST);
            marked++;
        }
    }
    if (marked) {
        if (m->stats_interval) m->stats.kick_src[2]++;
        __asm__ volatile("sev" ::: "memory");
    }
    return marked;
}

/* Deadline filter. CPU0 retains the original periodic device poll;
   timer writes publish deadlines and actual interrupts/requests still kick directly. */
unsigned hv_machine_kick_due(HvMachine *m, uint64_t now) {
    unsigned marked = 0, due_count = 0, unknown = 0, deferred = 0, polls = 0;
    for (int i = 0; i < m->ncpus; i++) {
        HvPerCpu *p = &m->percpu[i];
        if (!m->cpus[i] || !__atomic_load_n(&p->active, __ATOMIC_SEQ_CST)) continue;
        uint32_t valid = __atomic_load_n(&p->timer_deadline_valid, __ATOMIC_ACQUIRE);
        uint64_t due = __atomic_load_n(&p->timer_deadline, __ATOMIC_ACQUIRE);
        if (i && valid && (!due || due > now)) { deferred++; continue; }
        if (!i) polls++;
        else if (valid) due_count++;
        else unknown++;
        __atomic_store_n(&m->cpus[i]->exit_req, 1, __ATOMIC_SEQ_CST); marked++;
    }
    atomic_fetch_add_explicit(&m->timer_kicks_cpu0, polls, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->timer_kicks_due, due_count, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->timer_kicks_unknown, unknown, memory_order_relaxed);
    atomic_fetch_add_explicit(&m->timer_kicks_deferred, deferred, memory_order_relaxed);
    if (marked) __asm__ volatile("sev" ::: "memory");
    return marked;
}

void hv_machine_halt(HvMachine *m, enum HvHaltReason reason) {
    for (int i = 0; i < m->ncpus; i++) if (m->cpus[i]) {
        /* CPU_ON resets a parked CPU under this lock. It must not erase a
           terminal halt while another CPU is shutting the machine down. */
        HvPerCpu *p = m->cpus[i]->pc_state;
        pthread_mutex_lock(&p->wake_mu);
        int running = HV_HALT_NONE;
        atomic_compare_exchange_strong(&m->cpus[i]->halted, &running, reason);
        pthread_mutex_unlock(&p->wake_mu);
    }
    /* CPU_OFF sleeps on wake_cv without a timeout. exit_req/SEV alone only
       interrupts translated code and cannot release that condition wait. */
    for (int i = 0; i < m->ncpus; i++)
        if (m->cpus[i]) hv_cpu_wake(m->cpus[i]);
}

/* Device work is for CPU 0, which polls the devices. */
void hv_machine_wake(HvMachine *m) {
    if (m->stats_interval) m->stats.kick_src[3]++;
    if (m->cpu) hv_cpu_wake(m->cpu);
}

void hv_machine_free(HvMachine *m) {
    if(m->quiesce_initialized)hv_quiesce_destroy(&m->quiesce);
    hv_jit_region_close(&m->jit);
    for (int i = 0; i < m->nram; i++) {
        free(m->ram[i].code_pages);
        free(m->ram[i].page_gen);
        free(m->ram[i].whint);
        free(m->ram[i].ijc_va);
    }
    free(m->blocks);
    free(m->jit_page_heads);
    for (int i = 0; i < HV_MAX_CPUS; i++) {
        if (m->percpu[i].thread) mach_port_deallocate(mach_task_self(), m->percpu[i].thread);
        hv_fastmem_free(m->percpu[i].fastmem);
        free(m->percpu[i].ijc);
        free(m->percpu[i].ijc_segments);
        free(m->percpu[i].ucode);
        free(m->percpu[i].cid_chunks);
        for (int k = 0; k < HV_STASHES; k++) {
            free(m->percpu[i].stash[k].slot);
            free(m->percpu[i].stash[k].ent);
        }
        if (m->locks_initialized) {
            pthread_mutex_destroy(&m->percpu[i].wake_mu);
            pthread_cond_destroy(&m->percpu[i].wake_cv);
            pthread_mutex_destroy(&m->percpu[i].req_mu);
        }
    }
    free(m->slots);
    free(m->slot_site);
    free(m->slot_stub);
    free(m->slot_cond);
    free(m->slot_xa);
    free(m->slot_xpa);
    free(m->xchained);
    free(m->slot_free);
    free(m->evict_words);
    if (m->locks_initialized) {
        pthread_mutex_destroy(&m->big_mu);
        pthread_cond_destroy(&m->big_cv);
        pthread_mutex_destroy(&m->dev_mu);
        pthread_mutex_destroy(&m->tr_mu);
        pthread_mutex_destroy(&m->stw_mu);
        pthread_cond_destroy(&m->stw_cv);
    }
    memset(m, 0, sizeof *m);
}

int hv_machine_add_ram(HvMachine *m, uint64_t pa, uint64_t size, void *host, int readonly) {
    if (m->nram == HV_MAX_RAM) return -1;
    HvRam *r = &m->ram[m->nram++];
    r->pa = pa;
    r->size = size;
    r->host = host;
    r->readonly = readonly;
    size_t pages = (size + (1u << HV_TLB_PAGE_BITS) - 1) >> HV_TLB_PAGE_BITS;
    r->pages_log2 = 0;
    while ((1ull << r->pages_log2) < pages) r->pages_log2++;
    /* A power of two, so translated code bounds-checks a page index with one shift (IC IVAU). */
    r->code_pages = calloc((size_t)1 << r->pages_log2, 1);
    if (!m->main_ram || size > m->main_ram->size) m->main_ram = r;
    r->page_gen = calloc(pages, sizeof *r->page_gen);
    r->npages = pages;
    r->whint = calloc(pages * HV_MAX_CPUS, sizeof *r->whint);
    r->ijc_va = calloc(pages, sizeof *r->ijc_va);
    return r->code_pages && r->page_gen && r->whint && r->ijc_va ? 0 : -1;
}

int hv_machine_add_mmio(HvMachine *m, uint64_t pa, uint64_t size, void *opaque,
                        uint64_t (*read)(void *, uint64_t, unsigned),
                        void (*write)(void *, uint64_t, uint64_t, unsigned), const char *name) {
    if (m->nmmio == HV_MAX_MMIO) return -1;
    m->mmio[m->nmmio++] = (HvMmio){pa, size, opaque, read, write, name, 0};
    return 0;
}

HvRam *hv_ram_lookup(HvMachine *m, uint64_t pa) {
    for (int i = 0; i < m->nram; i++) {
        HvRam *r = &m->ram[i];
        if (pa - r->pa < r->size) return r;
    }
    return NULL;
}

void hv_block_index_add(HvMachine *m,uint32_t index) {
    HvBlock *b=&m->blocks[index];uintptr_t address=(uintptr_t)b->code,base=(uintptr_t)m->jit.base;
    size_t page=(address-base)>>14;b->host_next=0;
    if(m->jit_page_heads&&address>=base&&page<m->jit_page_count){b->host_next=m->jit_page_heads[page];m->jit_page_heads[page]=index+1;}
}

HvBlock *hv_block_at(HvMachine *m,const uint32_t *pc) {
    /* Diagnostic nearest entry, as before, but independent of birth/FIFO order.
       The caller must serialize descriptor compaction. No executable pointer
       is recovered from this diagnostic index. */
    uintptr_t address=(uintptr_t)pc,base=(uintptr_t)m->jit.base;
    if(address<base||address-base>=m->jit.capacity*4)return NULL;
    uintptr_t segment_base=base;
    if(m->jit.seg_words)segment_base=base+((address-base)/(m->jit.seg_words*4))*m->jit.seg_words*4;
    HvBlock *best=NULL;
    if(m->jit_page_heads) {
        size_t page=(address-base)>>14,first=(segment_base-base)>>14;
        for(;;){
            uint32_t link=m->jit_page_heads[page],remaining=(uint32_t)m->nblocks;
            while(link && link<=(uint32_t)m->nblocks && remaining--) {
                HvBlock *b=&m->blocks[link-1];
                if((uintptr_t)b->code<=address&&(uintptr_t)b->code>=segment_base&&(!best||(uintptr_t)b->code>(uintptr_t)best->code))best=b;
                link=b->host_next;
            }
            if(best||page==first)break;page--;
        }
    } else {
        for(int i=0;i<m->nblocks;i++){HvBlock *b=&m->blocks[i];if((uintptr_t)b->code>=segment_base&&(uintptr_t)b->code<=address&&(!best||(uintptr_t)b->code>(uintptr_t)best->code))best=b;}
    }
    return best;
}

uint32_t *hv_smc_counts;
uint64_t *hv_smc_last;
uint64_t hv_smc_pages, hv_smc_cpu, hv_smc_dma;

void hv_invalidate_code(HvMachine *m, uint64_t pa) {
    HvRam *r = hv_ram_lookup(m, pa);
    if (!r) return;
    uint64_t pg = (pa - r->pa) >> HV_TLB_PAGE_BITS;
    if (!r->code_pages[pg]) return;
    /* Blocks remember the generation they were made under; a stale one is
       retranslated the next time it is looked up. The block running now may
       finish with the old code, as it would with a real instruction pipeline. */
    r->code_pages[pg] = 0;
    __atomic_add_fetch(&r->page_gen[pg], 1, __ATOMIC_SEQ_CST);
    m->stats.flush_smc++;
    if (hv_smc_counts && pg < hv_smc_pages) {
        hv_smc_counts[pg]++;
        uint64_t caller = hv_self ? hv_self->pc : 0;
        hv_smc_last[pg] = caller;
        if (hv_self) hv_smc_cpu++;
        else hv_smc_dma++;
    }
    /* Exits from other pages chained into the stale blocks go back to their stub
       (whose next chain finds the new translation). Under the translation lock,
       as chaining them is: one that saw the old generation is done by now. */
    pthread_mutex_lock(&m->tr_mu);
    uint64_t tpa = (r->pa + (pg << HV_TLB_PAGE_BITS)) | 1;
    uint32_t *link = &m->xchain_heads[hv_xchain_bucket(tpa)];
    while (*link) {
        uint32_t idx = *link - 1;
        __atomic_add_fetch(&m->xchain_examined, 1, __ATOMIC_RELAXED);
        if (m->slot_xpa[idx] != tpa) {
            link = &m->xchained[idx];
            continue;
        }
        *link = m->xchained[idx];
        m->xchained[idx] = 0;
        m->nxchained--;
        __atomic_add_fetch(&m->xchain_removed, 1, __ATOMIC_RELAXED);
        m->slot_xpa[idx] = 0;
        __atomic_store_n(&m->slots[idx], 0, __ATOMIC_RELEASE);
        uint32_t *site = m->slot_site[idx];
        if (site) {
            uint32_t insn = 0x14000000u | (uint32_t)((m->slot_stub[idx] - site) & 0x3ffffff); /* back to its stub */
            hv_jit_write(&m->jit, site, &insn, 4);
            hv_jit_finish(&m->jit, site, 1);
        }
    }
    pthread_mutex_unlock(&m->tr_mu);
    /* The indirect-branch cache may lead into the stale blocks: drop those entries (or, without HV_IJC_PAGES, the
       whole cache), here at once and on the other CPUs before they next leave a block (their cache lookups and
       chained exits check exit_req first). Which entries: the page's blocks were cached under one VA page (ijc_va,
       read after the generation went up; a fill notes its page before checking the generation, see
       hv_ijc_fill_checked), so only that page's; under none, only the return predictions go; under several, all. */
    uint64_t v = __atomic_exchange_n(&r->ijc_va[pg], 0, __ATOMIC_SEQ_CST);
    if (!hv_knob[HV_K_IJCPAGES]) v = ~0ull;
    if (m->stats_interval) m->stats.code_ijc[!v ? 0 : v == ~0ull ? 2 : 1]++;
    if (!v) v = 1;
    for (int i = 0; i < m->ncpus; i++) {
        HvCpu *c = m->cpus[i];
        if (!c) continue;
        /* Only a CPU may reset its own cache; from any other thread (a device,
           or no CPU running yet) it is a request, or a running CPU could read a
           half-written entry and jump into the wrong code. */
        if (c == hv_self) {
            if (v == ~0ull) {
                hv_ijc_reset(c, 0);
                hv_ijc_reset(c, 1);
            } else {
                hv_ijc_drop_code_page(c, v);
            }
        } else if (v == ~0ull) {
            hv_cpu_post(c, HV_REQ_IJC_RESET);
        } else {
            hv_cpu_post_ijc_page(c, v);
        }
    }
    m->stats.reset_why[4]++;
    /* Make a running chain leave (chains stay patched: see chain() in dispatch.c). */
    hv_machine_kick_all(m);
}

void hv_dma_written(HvMachine *m, uint64_t pa, uint64_t len) {
    HvRam *r = hv_ram_lookup(m, pa);
    if (!r || !len || pa + len - r->pa > r->size) return;
    uint64_t first = (pa - r->pa) >> HV_TLB_PAGE_BITS, last = (pa + len - 1 - r->pa) >> HV_TLB_PAGE_BITS;
    for (uint64_t pg = first; pg <= last; pg++)
        if (__atomic_load_n(&r->code_pages[pg], __ATOMIC_ACQUIRE)) hv_invalidate_code(m, r->pa + (pg << HV_TLB_PAGE_BITS));
}

HvMmio *hv_mmio_lookup(HvMachine *m, uint64_t pa) {
    for (int i = 0; i < m->nmmio; i++) {
        HvMmio *d = &m->mmio[i];
        if (pa - d->pa < d->size) return d;
    }
    return NULL;
}

void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) {
    HvRam *r = hv_ram_lookup(m, pa);
    /* Lookup established that pa is inside the region. Subtract before
       comparing the length so an untrusted 64-bit span cannot wrap. */
    if (!r || len > r->size - (pa - r->pa)) return NULL;
    return r->host + (pa - r->pa);
}

/* MMIO is accessed in naturally sized pieces of at most 8 bytes. */
int hv_phys_read(HvMachine *m, uint64_t pa, void *buf, unsigned len) {
    if (!len) return 0;
    void *p = hv_phys_ptr(m, pa, len);
    if (p) {
        memcpy(buf, p, len);
        return 0;
    }
    HvMmio *d = hv_mmio_lookup(m, pa);
    if (!d || len > 8) return -1;
    if (!d->self_locked) hv_dev_lock(m);
    uint64_t v = d->read ? d->read(d->opaque, pa - d->pa, len) : 0;
    if (!d->self_locked) hv_dev_unlock(m);
    memcpy(buf, &v, len);
    if (m->log >= 3)
        fprintf(stderr, "mmio read  %s+%llx size %u = %llx pc %llx\n", d->name, (unsigned long long)(pa - d->pa), len,
                (unsigned long long)v, (unsigned long long)m->access_pc);
    return 0;
}

int hv_phys_write(HvMachine *m, uint64_t pa, const void *buf, unsigned len) {
    if (!len) return 0;
    HvRam *r = hv_ram_lookup(m, pa);
    if (r && len <= r->size - (pa - r->pa)) {
        if (r->readonly) return 0; /* ROM: writes are ignored */
        uint64_t off = pa - r->pa;
        uint64_t first = off >> HV_TLB_PAGE_BITS, last = (off + len - 1) >> HV_TLB_PAGE_BITS;
        for (uint64_t pg = first; pg <= last; pg++)
            if (r->code_pages[pg]) hv_invalidate_code(m, r->pa + (pg << HV_TLB_PAGE_BITS)); /* a write to code */
        if (m->watch_pa && m->watch_pa - pa < len) {
            uint64_t v = 0;
            memcpy(&v, (const uint8_t *)buf + (m->watch_pa - pa), len - (m->watch_pa - pa) < 8 ? len - (m->watch_pa - pa) : 8);
            fprintf(stderr, "hengevm: watch: write to pa %llx = %llx (%u bytes at pa %llx) by pc %llx\n",
                    (unsigned long long)m->watch_pa, (unsigned long long)v, len, (unsigned long long)pa,
                    (unsigned long long)m->access_pc);
        }
        memcpy(r->host + off, buf, len);
        return 0;
    }
    HvMmio *d = hv_mmio_lookup(m, pa);
    if (!d || len > 8) return -1;
    uint64_t v = 0;
    memcpy(&v, buf, len);
    if (m->log >= 3)
        fprintf(stderr, "mmio write %s+%llx size %u = %llx pc %llx\n", d->name, (unsigned long long)(pa - d->pa), len,
                (unsigned long long)v, (unsigned long long)m->access_pc);
    if (!d->self_locked) hv_dev_lock(m);
    if (d->write) d->write(d->opaque, pa - d->pa, v, len);
    if (!d->self_locked) hv_dev_unlock(m);
    return 0;
}

void hv_cpu_reset(HvCpu *cpu, HvMachine *m) {
    hv_cpu_reset_index(cpu, m, 0);
}

void hv_ijc_evict_index(HvCpu *cpu) {
    HvPerCpu *p=cpu->pc_state;unsigned n=cpu->m->jit.nseg;
    if(!p || (p->ijc_segments && p->ijc_segment_count==n))return;
    free(p->ijc_segments);p->ijc_segments=NULL;p->ijc_segment_count=0;
    if(!n)return;
    p->ijc_segments=calloc((size_t)n*HV_IJC_SEGMENT_WORDS,sizeof(uint64_t));
    if(p->ijc_segments)p->ijc_segment_count=n;
}

void hv_cpu_reset_index(HvCpu *cpu, HvMachine *m, uint32_t index) {
    /* Everything but m and pc_state: other CPUs' TLBIs read those of a CPU
       being started (PSCI CPU_ON) at any time. */
    _Static_assert(offsetof(HvCpu, m) < offsetof(HvCpu, pc_state), "HvCpu layout");
    size_t a = offsetof(HvCpu, m), b = offsetof(HvCpu, pc_state);
    memset(cpu, 0, a);
    memset((char *)cpu + a + sizeof cpu->m, 0, b - a - sizeof cpu->m);
    memset((char *)cpu + b + sizeof cpu->pc_state, 0, sizeof *cpu - b - sizeof cpu->pc_state);
    cpu->m = m;
    cpu->index = index;
    cpu->cntvoff = m->cntvoff;
    cpu->pc_state = &m->percpu[index];
    m->cpus[index] = cpu;
    if (m->ncpus <= (int)index) m->ncpus = (int)index + 1;
    if (index == 0) m->cpu = cpu;
    HvPerCpu *p = cpu->pc_state;
    p->jit_seen=0;p->jit_sample_count=0;
    hv_ijc_evict_index(cpu);
    /* Ids start over, so entries tagged with the old ones must go. */
    for (int t = 0; t < HV_IJC_TABLES; t++)
        if (p->ijc_tables_used >> t & 1) memset(p->ijc + (size_t)t * (HV_IJC_TABLE_BYTES / 8), 0, HV_IJC_TABLE_BYTES);
    p->ijc_tables_used = 0;
    memset(p->ijc_keyed, 0, sizeof p->ijc_keyed);
    p->ijc_keyed_count = 0;
    memset(p->ijc_pages, 0, sizeof p->ijc_pages);
    memset(p->ijc_hint, 0, sizeof p->ijc_hint);
    memset(p->jc, 0, sizeof p->jc);
    memset(p->ijc_sites,0,sizeof p->ijc_sites);
    cpu->ijc_site_hints=(uint64_t)(uintptr_t)p->ijc_sites;
    cpu->ijc = (uint64_t)(uintptr_t)p->ijc;
    cpu->lines_ptr = (uint64_t)(uintptr_t)&p->irq_line;
    for (int t = 0; t < HV_IJC_TABLES; t++) cpu->ijc_tab[t] = (uint64_t)(uintptr_t)(p->ijc + (size_t)t * (HV_IJC_TABLE_BYTES / 8));
    hv_ret_clear(cpu);
    cpu->next_cid = 1;
    cpu->kernel_gen = 1;
    cpu->ijc_salt[1] = 1ull << 48; /* tags of an all-zero table never match */
    hv_ijc_switch(cpu);
    cpu->exit_routine = (uint64_t)hv_exit;
    cpu->helper_routine = (uint64_t)hv_helper_entry;
    cpu->helper_thunk = (uint64_t)hv_helper_thunk;
    cpu->chain_thunk = (uint64_t)hv_chain_thunk;
    cpu->ijc_thunk = (uint64_t)hv_ijc_thunk;
    cpu->xjump_thunk = (uint64_t)hv_xjump_thunk;
    cpu->el = 1;
    cpu->spsel = 1;
    cpu->daif = HV_PSTATE_DAIF;
    cpu->excl_addr = ~0ull;
    /* Architectural reset value has the MMU and caches off; RES1 bits set. */
    cpu->sctlr_el1 = 0x30d00980; /* RES1 bits, and ITD and SED, which read as 1 without AArch32 at EL0 */
    cpu->nkernel_fills = HV_KERNEL_FILLS + 1; /* nothing is logged yet: make every entry invalid */
    if (hv_fastmem_attach(cpu, &p->fastmem, m->fastmem_enabled) != 0)
        fprintf(stderr, "henge: kernel read cache unavailable on CPU %u; using the TLB\n", index);
    hv_tlb_flush(cpu);
}
