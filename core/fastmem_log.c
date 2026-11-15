#include "fastmem.h"
#include "machine.h"
#include <sys/resource.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif

/* Host-only reporting: separate from the scalar-only light refill module. */

void hv_fastmem_log(HvMachine *m, FILE *out) {
    uint64_t sleeps = 0, timeouts = 0, errors = 0;
    for (int i = 0; i < m->ncpus; i++) {
        sleeps += __atomic_load_n(&m->percpu[i].sync_sleeps, __ATOMIC_RELAXED);
        timeouts += __atomic_load_n(&m->percpu[i].sync_timeouts, __ATOMIC_RELAXED);
        errors += __atomic_load_n(&m->percpu[i].sync_errors, __ATOMIC_RELAXED);
    }
    fprintf(out, "cpu-sync: sleep_enabled=%d waits=%llu timeouts=%llu errors=%llu (cumulative; acknowledgement semantics retained)\n",
            !!hv_knob[HV_K_SYNCWAIT], (unsigned long long)sleeps, (unsigned long long)timeouts, (unsigned long long)errors);
    fprintf(out, "code-invalidation: index=physical-page examined=%llu removed=%llu (cumulative; bucket collisions checked)\n",
            (unsigned long long)__atomic_load_n(&m->xchain_examined, __ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->xchain_removed, __ATOMIC_RELAXED));
    uint64_t wfe_ticks = 0, wfe_timeouts = 0, wfe_dispatches = 0;
    for (int i = 0; i < m->ncpus; i++) {
        wfe_ticks += __atomic_load_n(&m->percpu[i].wfe_ticks, __ATOMIC_RELAXED);
        wfe_timeouts += __atomic_load_n(&m->percpu[i].wfe_timeouts, __ATOMIC_RELAXED);
        wfe_dispatches += __atomic_load_n(&m->percpu[i].wfe_dispatches, __ATOMIC_RELAXED);
    }
    fprintf(out, "cpu-wfe: accumulated_counter_ticks=%llu timeouts=%llu counter_hz=24000000 unmonitored_exits=%llu stats_enabled=%d (not a measurement of low-power residency)\n",
            (unsigned long long)wfe_ticks, (unsigned long long)wfe_timeouts, (unsigned long long)wfe_dispatches, m->stats_interval != 0);
#ifdef __APPLE__
    if (getenv("HV_TASK_STATS") && !strcmp(getenv("HV_TASK_STATS"), "1")) {
        task_power_info_data_t power = {0};
        mach_msg_type_number_t count = TASK_POWER_INFO_COUNT;
        kern_return_t kr = task_info(mach_task_self(), TASK_POWER_INFO, (task_info_t)&power, &count);
        if (kr == KERN_SUCCESS)
            fprintf(out, "task-wakeups: interrupt=%llu platform_idle=%llu timer_bin1=%llu timer_bin2=%llu (cumulative kernel counters; not watts)\n",
                (unsigned long long)power.task_interrupt_wakeups,(unsigned long long)power.task_platform_idle_wakeups,
                (unsigned long long)power.task_timer_wakeups_bin_1,(unsigned long long)power.task_timer_wakeups_bin_2);
        else fprintf(out, "task-wakeups: unavailable kr=%d\n", kr);
    }
#endif
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        unsigned long long user_ms = (unsigned long long)usage.ru_utime.tv_sec * 1000 + usage.ru_utime.tv_usec / 1000;
        unsigned long long system_ms = (unsigned long long)usage.ru_stime.tv_sec * 1000 + usage.ru_stime.tv_usec / 1000;
        fprintf(out, "host-cpu: user_ms=%llu system_ms=%llu (cumulative process CPU; compare deltas with guest elapsed time)\n", user_ms, system_ms);
    }
    fprintf(out, "jit-work: translations=%llu guest_insns=%llu approximate_retranslations=%llu capacity_flush_requests=%llu block_limit_flush_requests=%llu (cumulative; flush requests can coalesce)\n",
            (unsigned long long)__atomic_load_n(&m->stats.translations, __ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->stats.translated_insns, __ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->stats.retrans_vapa, __ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->stats.flush_capacity, __ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->stats.flush_block_limit, __ATOMIC_RELAXED));
    fprintf(out, "jit-allocation: tail_allocations=%llu failed_reservation_consumes_space=no (cumulative; no persistent code cache)\n",
            (unsigned long long)__atomic_load_n(&m->stats.jit_tail_allocations, __ATOMIC_RELAXED));
    fprintf(out, "jit-dedup: avoided_placements=%llu avoided_code_bytes=%llu late_duplicates=%llu (cumulative; emission and exit-slot allocation still occur)\n",
            (unsigned long long)__atomic_load_n(&m->stats.duplicate_place_avoided, __ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->stats.duplicate_bytes_avoided, __ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->stats.duplicate_place_late, __ATOMIC_RELAXED));
    uint64_t words = hv_jit_extent(&m->jit);
    uint64_t capacity = m->jit.limit && m->jit.limit < m->jit.capacity ? m->jit.limit : m->jit.capacity;
    fprintf(out, "jit-cache: storage=RAM persistent=no precompile_all=no used=%.1fMiB capacity=%.1fMiB full=%.1f%% blocks=%d full_flushes=%llu resets=%llu (fresh at app launch; guest disk/browser caches are separate)\n",
            (double)words * 4 / (1u << 20), (double)capacity * 4 / (1u << 20),
            capacity ? 100.0 * (double)words / (double)capacity : 0.0, m->nblocks,
            (unsigned long long)__atomic_load_n(&m->stats.flush_full, __ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->stats.block_flushes, __ATOMIC_RELAXED));
    fprintf(out,"jit-publication: rewritten_words=%llu invalidated_lines=%llu bitmap_batches=%llu (cumulative; complete publication barriers retained)\n",
            (unsigned long long)__atomic_load_n(&m->jit.publication_words,__ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->jit.publication_lines,__ATOMIC_RELAXED),
            (unsigned long long)__atomic_load_n(&m->jit.publication_bitmap_batches,__ATOMIC_RELAXED));
    fprintf(out,"jit-ring: segments=%u evictions=%llu blocks_dropped=%llu exits_repaired=%llu (quiescent nonmoving segment reuse; full flush fallback retained)\n",
        m->jit.nseg,(unsigned long long)m->stats.evictions,(unsigned long long)m->stats.evict_blocks,(unsigned long long)m->stats.evict_unchained);
    fprintf(out,"jit-branch-preservation: examined=%llu removed=%llu preserved_observations=%llu (indexed quiescent eviction; return/descriptor resets retained)\n",(unsigned long long)__atomic_load_n(&m->ijc_evict_examined,__ATOMIC_RELAXED),(unsigned long long)__atomic_load_n(&m->ijc_evict_removed,__ATOMIC_RELAXED),(unsigned long long)__atomic_load_n(&m->ijc_evict_preserved,__ATOMIC_RELAXED));
    fprintf(out,"jit-retention: enabled=%d nonfifo=%llu activity_source=cache-hits-and-decimated-helpers no_poll_timer=1 code_moves=0 (heuristic policy; not an FPS claim)\n",m->jit_retention,(unsigned long long)__atomic_load_n(&m->jit.retention_nonfifo,__ATOMIC_RELAXED));
    fprintf(out,"branch-dispatch: paired-load=%d site-hints=%d hint_emissions=%llu (tag/ASID/flag checks retained; emissions are not hits)\n",m->ijc_pair,m->branch_site_hints,(unsigned long long)__atomic_load_n(&m->branch_hint_emissions,__ATOMIC_RELAXED));
    fprintf(out, "fastmem: mode=%s counters=%s (cumulative; diagnostic counting adds overhead)\n",
            m->fastmem_enabled ? "on" : "off", m->fastmem_diagnostics ? "on" : "off");
    if (m->fastmem_enabled) fprintf(out, "fastmem-layout: tagged-multiwindow entries=262144 per-PAN bytes-per-CPU=10485760 (bounded allocation; exact VA tags; all kernel windows)\n");
    if (!m->fastmem_enabled || !m->fastmem_diagnostics) return;
    for (int i = 0; i < m->ncpus; i++) {
        HvCpu *c = m->cpus[i];
        if (!c) continue;
        HvFastmemSnapshot fm;
        if (!hv_fastmem_snapshot(c, &fm)) { fprintf(out, "fastmem: cpu=%d unavailable; ordinary TLB fallback\n", i); continue; }
#define SNAP(x) ((unsigned long long)__atomic_load_n(&(x), __ATOMIC_RELAXED))
        unsigned long long attempts = SNAP(c->fm_attempts), hits = SNAP(c->fm_hits);
        fprintf(out, "fastmem: cpu=%d layout=tagged-multiwindow attempts=%llu hits=%llu hit_pct=%.2f fallback[nonkernel=%llu unavailable=%llu empty_tag_or_page_end=%llu reserved=%llu] fills=%llu full_clears=%llu range_drops=%llu list_full=%llu\n",
                i, attempts, hits, attempts ? 100.0 * (double)hits / (double)attempts : 0.0,
                SNAP(c->fm_misses[0]), SNAP(c->fm_misses[1]), SNAP(c->fm_misses[2]), SNAP(c->fm_misses[3]),
                (unsigned long long)fm.fills, (unsigned long long)fm.clears, (unsigned long long)fm.drops, (unsigned long long)fm.saturated);
#undef SNAP
    }
}
