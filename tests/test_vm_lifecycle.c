#include "henge-vm.h"
#include "henge-ios-jit.h"
#include "install.h"
#include "jit_region.h"
#include "vm.h"
#include "disk.h"
#include "dispatch.h"
#include "snapshot.h"

#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <signal.h>

/* Real native bridge and device workers; only the debugger allocation and
   unused installer entry point are replaced. No Apple ROM or disk needed. */
extern void hv_snapshot_test_fail_after(int n);
extern void hv_snapshot_test_fail_persistently(int n);
extern int hv_snapshot_test_packing_retries(void);
extern void henge_vm_test_write_lock(int held);
extern void hv_snapshot_test_progress(void (*hook)(uint64_t));
static pthread_mutex_t save_gate_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t save_gate_cv = PTHREAD_COND_INITIALIZER;
static int save_gate_entered, save_gate_release;
static HengeSaveRequest *saving_request;
static const char *saving_path;
static int save_result;
static char save_error[256];
static void save_gate(uint64_t scanned) {
    if (scanned < (4u << 20)) return;
    pthread_mutex_lock(&save_gate_mu);
    save_gate_entered = 1; pthread_cond_broadcast(&save_gate_cv);
    while (!save_gate_release) pthread_cond_wait(&save_gate_cv,&save_gate_mu);
    pthread_mutex_unlock(&save_gate_mu);
}
static void *save_on_thread(void *unused) {
    (void)unused;
    save_result=henge_vm_save_run(saving_request,saving_path,"test",save_error,sizeof save_error);
    return NULL;
}
typedef struct CancelAtProgress { _Atomic int cancelled; uint64_t scanned; } CancelAtProgress;
static int cancel_at_progress(void *p) { return atomic_load(&((CancelAtProgress *)p)->cancelled); }
static void cancel_after_chunk(uint64_t scanned,uint64_t total,void *p) {
    CancelAtProgress *c=p;
    if (scanned > c->scanned) c->scanned=scanned;
    if (scanned >= (4u << 20) && scanned<total) atomic_store(&c->cancelled,1);
}
static HvJitRegion jit;
static HengeDualMapping mapping;
static int failures;
static _Atomic int reader_done;
static _Atomic int stats_requested, stats_completed;
static void stats_stop_hook(HvCpu *cpu) {
    int request = atomic_load(&stats_requested);
    if (request == atomic_load(&stats_completed)) return;
    /* Real formatter and Mach thread time on CPU0, never the test/UI thread. */
    hv_dispatch_log_stats(cpu);
    atomic_store(&stats_completed, request);
}
static void stats_observe(void) {
    int request = atomic_fetch_add(&stats_requested, 1) + 1;
    for (int n = 0; n < 5000 && atomic_load(&stats_completed) != request; n++) usleep(1000);
    if (atomic_load(&stats_completed) != request) {
        fprintf(stderr, "CPU0 reporting hook timed out: blocks=%llu interval=%d chain=%d index=%u\n",
                (unsigned long long)hv_vm_machine()->stats.blocks, hv_vm_machine()->stats_interval,
                hv_vm_machine()->chain, hv_vm_cpu(0)->index);
        exit(1);
    }
}
static void stats_measure_run(void) {
    stats_observe(); /* baseline acknowledgement from this actual CPU0 thread */
    usleep(1100000); /* a deliberate CPU-time measurement interval */
    stats_observe(); /* do not depend on an aggregate counter hitting a 64K multiple */
    henge_vm_log_cache(); /* real per-vCPU host CPU accounting, including after Continue */
}
HengeDualMapping *henge_ios_jit_get_mapping(void) { return &mapping; }
void hv_prof_ios_start(void) {}
int hv_install_start(HvVirtioUsb *usb, const char *ipsw, const char *work, uint64_t ecid,
                     HvInstallProgress progress, void *user) {
    (void)usb; (void)ipsw; (void)work; (void)ecid; (void)progress; (void)user;
    return -1;
}
static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}
static void check_cpu_identity(void) {
    HvCpu *cpu=hv_vm_cpu(0);
    thread_basic_info_data_t info;
    mach_msg_type_number_t count=THREAD_BASIC_INFO_COUNT;
    pthread_mutex_lock(&cpu->pc_state->req_mu);
    mach_port_t thread=__atomic_load_n(&cpu->pc_state->thread,__ATOMIC_ACQUIRE);
    kern_return_t result=thread ? thread_info(thread,THREAD_BASIC_INFO,(thread_info_t)&info,&count) : KERN_INVALID_ARGUMENT;
    pthread_mutex_unlock(&cpu->pc_state->req_mu);
    check("bounded capture can account for the running CPU with regular statistics off",result==KERN_SUCCESS);
}
static int fds(void) {
    int n = 0;
    for (int i = 0; i < 2048; i++) if (fcntl(i, F_GETFD) != -1) n++;
    return n;
}
static unsigned threads(void) {
    thread_act_array_t list;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return 0;
    for (unsigned i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), list[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof *list);
    return n;
}
static unsigned dead_ports(void) {
    mach_port_name_array_t names;
    mach_port_type_array_t types;
    mach_msg_type_number_t n, nt;
    if (mach_port_names(mach_task_self(), &names, &n, &types, &nt) != KERN_SUCCESS) exit(1);
    unsigned dead = 0;
    for (unsigned i = 0; i < nt; i++) if (types[i] & MACH_PORT_TYPE_DEAD_NAME) dead++;
    vm_deallocate(mach_task_self(), (vm_address_t)names, n * sizeof *names);
    vm_deallocate(mach_task_self(), (vm_address_t)types, nt * sizeof *types);
    return dead;
}
static void write_file(const char *path, const void *data, size_t bytes) {
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0 || (data && write(fd, data, bytes) != (ssize_t)bytes) || ftruncate(fd, bytes)) exit(1);
    close(fd);
}
static void *foreign_signal_stack(void *unused) {
    (void)unused;
    stack_t before = {0}, after = {0};
    if (sigaltstack(NULL, &before)) { perror("query foreign signal stack"); return (void *)11; }
    void *owned = NULL;
    if (before.ss_flags & SS_DISABLE) {
        owned = mmap(NULL, 65536, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (owned == MAP_FAILED) return (void *)1;
        before = (stack_t){.ss_sp=owned,.ss_size=65536};
        if (sigaltstack(&before, NULL)) { perror("install foreign signal stack"); return (void *)1; }
        if (sigaltstack(NULL, &before)) { perror("query foreign signal stack"); return (void *)11; }
    }
    hv_vm_prepare_cpu_thread();
    int bad = sigaltstack(NULL, &after) || after.ss_sp != before.ss_sp || after.ss_size != before.ss_size;
    if (bad) fprintf(stderr, "signal stack changed: before=%p/%zu flags=%x after=%p/%zu flags=%x\n",
                     before.ss_sp, before.ss_size, before.ss_flags, after.ss_sp, after.ss_size, after.ss_flags);
    if (owned) {
        stack_t disabled = {.ss_sp=owned,.ss_size=65536,.ss_flags=SS_DISABLE};
        if (sigaltstack(&disabled, NULL)) { perror("disable foreign signal stack"); bad = 15; }
        else if (munmap(owned, 65536)) { perror("unmap foreign signal stack"); bad = 16; }
    }
    return (void *)(uintptr_t)bad;
}
typedef struct SaveAttempt { const char *path; int result; } SaveAttempt;
static void *save_together(void *opaque) {
    SaveAttempt *attempt = opaque;
    char error[256];
    attempt->result = henge_vm_save(attempt->path, "test", error, sizeof error);
    if (attempt->result) fprintf(stderr, "parallel save: %s\n", error);
    return NULL;
}
static void *read_ui(void *unused) {
    (void)unused;
    while (!atomic_load(&reader_done)) {
        uint8_t image[16];
        int x, y, width, height, stride;
        const uint8_t *pixels;
        henge_vm_snapshot(image, 2, 2);
        henge_vm_pointer(&x, &y);
        henge_vm_cpus_on();
        henge_vm_link_connected(0);
        henge_vm_gpu_frames();
        HengeVmCounters counters;
        henge_vm_counters(&counters);
        henge_vm_balloon(-1);
        henge_vm_set_display_layer(NULL);
        if (!henge_vm_boot_display(&pixels, &width, &height, &stride)) henge_vm_free_display(pixels);
        usleep(500);
    }
    return NULL;
}
static _Atomic unsigned state_signals;
static void state_changed(void) { atomic_fetch_add(&state_signals, 1); }
int main(void) {
    alarm(120);
    henge_vm_set_state_notify(state_changed);
    HengeVmObservation observation;memset(&observation,0x55,sizeof observation);
    HengeVmDisplayMode observed_mode;
    henge_vm_test_write_lock(1);
    check("UI observation never waits for lifecycle writer",henge_vm_try_observation(&observation)==0 &&
          henge_vm_display_mode(1,&observed_mode)==-2);
    const uint8_t *boot_pixels=NULL;int boot_w=0,boot_h=0,boot_stride=0;
    check("firmware display never waits for lifecycle writer",henge_vm_boot_display(&boot_pixels,&boot_w,&boot_h,&boot_stride)==-1);
    henge_vm_trim_memory(); /* memory warnings also cannot block on the writer */
    HengeVmResources busy_resources;
    HengeGuestMemoryStatus busy_memory;
    henge_vm_guest_memory(&busy_memory);
    check("guest RAM status never waits for lifecycle writer",busy_memory.state==-1 && !busy_memory.bytes && !busy_memory.backing);
    henge_vm_capture_timing(1);henge_vm_capture_timing(0);
    henge_vm_resources(&busy_resources);henge_vm_log_cache();
    check("diagnostics never wait for lifecycle writer",busy_resources.state==-1 && !(busy_resources.available&8));
    henge_vm_test_write_lock(0);
    check("observation resumes after lifecycle ownership",henge_vm_try_observation(&observation)==1 && observation.counters.state==0);

    char dir[] = "/tmp/henge-lifecycle-XXXXXX", rom[256], disk[256], aux[256], ram[256], error[256];
    if (!mkdtemp(dir) || hv_jit_region_open(&jit, 8 << 20)) return 1;
    snprintf(rom, sizeof rom, "%s/rom", dir);
    snprintf(disk, sizeof disk, "%s/disk", dir);
    snprintf(aux, sizeof aux, "%s/aux", dir);
    snprintf(ram, sizeof ram, "%s/ram", dir);
    setenv("HV_RAM_FILE", ram, 1);
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_BALLOON", "0", 1);
    write_file(disk, NULL, 1 << 20);
    write_file(aux, NULL, 1 << 20);
    mapping = (HengeDualMapping){.rx_addr = (uint8_t *)jit.base,
        .rw_addr = (uint8_t *)jit.base + jit.rw_diff, .size = jit.capacity * 4};
    pthread_t probe; void *probe_result = NULL;
    if (pthread_create(&probe, NULL, foreign_signal_stack, NULL) || pthread_join(probe, &probe_result)) return 1;
    if (probe_result) fprintf(stderr, "signal-stack probe failure=%lu\n", (unsigned long)(uintptr_t)probe_result);
    check("existing runtime signal stack retained", probe_result == NULL);
    pthread_t reader;
    if (pthread_create(&reader, NULL, read_ui, NULL)) return 1;
    /* Warm the process-wide pointer queue before counting worker threads. */
    hv_vm_mouse_move(0, 0);
    usleep(100000);
    int initial_fds = fds();
    unsigned initial_threads = threads();
    unsigned initial_dead_ports = dead_ports();
    /* Missing ROM fails after disks, RAM and device workers were created. */
    for (int i = 0; i < 3; i++) {
        check("failed boot reports an error", henge_vm_boot(rom, disk, aux, 1, 0, 64, 4, error, sizeof error) != 0);
        check("failed boot delivered state signals", atomic_load(&state_signals) >= 2);
        check("failed boot allows retry", henge_vm_state() == 0 && henge_vm_can_start());
        check("failed boot closes files", fds() == initial_fds);
        check("failed boot joins workers", threads() == initial_threads);
    }
    for (int i = 0; i < 12; i++) {
        int outcome = i % 3 == 2 ? HENGE_VM_OUTCOME_HOST_STOP : i % 3 == 1 ? HENGE_VM_OUTCOME_RESTART : HENGE_VM_OUTCOME_SHUTDOWN;
        uint32_t code[] = {outcome == HENGE_VM_OUTCOME_RESTART ? 0xd2800120 : 0xd2800100, 0xf2b08000, 0xd4000002};
        if (outcome == HENGE_VM_OUTCOME_HOST_STOP) code[0] = 0x14000000;
        write_file(rom, code, sizeof code);
        int rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 4, error, sizeof error);
        if (rc) fprintf(stderr, "boot %d: %s\n", i, error);
        check("boot succeeds without restarting app", rc == 0);
        if (rc) break;
        if (outcome == HENGE_VM_OUTCOME_HOST_STOP) {
            henge_vm_mouse_button(0, 1);
            henge_vm_mouse_button(1, 1);
            henge_vm_mouse_move(5, 7);
            henge_vm_mouse_button(1, 0);
            henge_vm_stop();
        }
        for (int n = 0; n < 3000 && henge_vm_state() != 2; n++) usleep(1000);
        check("terminal state is published after cleanup", henge_vm_state() == 2);
        if (henge_vm_state() != 2) exit(1);
        check("power outcome preserved", henge_vm_exit_outcome() == outcome);
        check("start is available again", henge_vm_can_start());
        check("Link mode can be configured for another boot", henge_vm_set_link_display(1920, 1351, 0, 0, 60) == 0);
        check("Link disabled before another boot", henge_vm_set_link_display(0, 0, 0, 0, 0) == 0);
        check("new generation", henge_vm_generation() == (uint64_t)i + 1);
        check("RAM released", hv_vm_board()->ram == NULL);
        check("RAM file closed", hv_vm_board()->ram_fd == -1);
        check("balloon released", hv_vm_board()->balloon == NULL);
        check("translation metadata released", hv_vm_machine()->blocks == NULL && hv_vm_machine()->jit.base == NULL);
        check("borrowed JIT mapping retained", mapping.rx_addr == (uint8_t *)jit.base);
        check("no disk or network descriptor leak", fds() == initial_fds);
        /* The last CPU thread can still be returning from its callback. */
        for (int n = 0; n < 1000 && threads() > initial_threads; n++) usleep(1000);
        check("no CPU, disk or network worker leak", threads() == initial_threads);
        check("no leaked CPU thread ports", dead_ports() == initial_dead_ports);
    }
    /* Instant resume: a counter in RAM goes on from where it was saved, in this machine and in a new one. */
    {
        char snap[300];
        snprintf(snap, sizeof snap, "%s/state.hsnap", dir);
        /* movz x1, #0x7000, lsl 16; loop: ldr x2, [x1]; add x2, x2, #1; str x2, [x1]; b loop */
        uint32_t code[] = {0xd2ae0001, 0xf9400022, 0x91000442, 0xf9000022, 0x17fffffd};
        write_file(rom, code, sizeof code);
        int rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 2, error, sizeof error);
        check("resume test boots", rc == 0);
        if (getenv("HENGE_TEST_STATS")) {
            /* Arrange an actual CPU-thread stop hook at the ROM loop entry.
               Statistics formatting is tested independently of the dispatch
               frequency heuristic; publication is acknowledged by CPU0. */
            if (henge_vm_pause(error, sizeof error)) return 1;
            check("statistics enabled on CPU0", hv_vm_machine()->stats_interval == 1 && hv_vm_cpu(0)->index == 0);
            hv_vm_machine()->chain = 0;
            hv_vm_machine()->stop_pc = (hv_vm_cpu(0)->pc & ~0x3fffull) + 4;
            hv_vm_machine()->stop_hook = stats_stop_hook;
            /* The original loop may already have a published self-link. Use
               the real quiescent cache flush, rather than only blocking new
               links, before restarting the reporting fixture. */
            hv_flush_blocks(hv_vm_machine());
            if (henge_vm_continue()) return 1;
            stats_measure_run();
        }
        usleep(50000);
        check_cpu_identity();
        uint64_t network_token=hv_vm_test_network_token();
        check("current deferred network event applies",hv_vm_test_network_apply(network_token,0)==1);
        henge_vm_key_hid(0xe4, 1);
        henge_vm_key_hid(0xe1, 1);
        henge_vm_key_hid(4, 1);
        hv_vm_touch(1, 0, 100, 100, 1);
        hv_vm_touch_button(1);
        henge_vm_mouse_button(1, 1);
        hv_dev_lock(hv_vm_machine());
        HvVirtioSnd *sound=hv_vm_board()->snd;
        sound->channels=2;sound->format=HV_VSND_FMT_S16;sound->rate=HV_VSND_RATE_48000;
        sound->rate_hz=48000;sound->frame_bytes=4;sound->prepared=1;sound->running=1;
        hv_dev_unlock(hv_vm_machine());
        rc = henge_vm_suspend(snap, "test", error, sizeof error);
        if (rc) fprintf(stderr, "suspend: %s\n", error);
        check("suspend saves", rc == 0 && henge_vm_state() == 4 && access(snap, F_OK) == 0);
        if (rc || henge_vm_state() != 4) {
            fprintf(stderr, "Suspend failed: refusing to inspect potentially released guest RAM\n");
            return 1;
        }
        check("pause preserves the guest audio stream",hv_vm_board()->snd->running==1 && hv_vm_board()->snd->prepared==1);
        check("pause fences deferred network events and restores an interrupted link",hv_vm_test_network_apply(network_token,0)==0 && hv_vm_board()->net->vio.config[6]==1);
        uint64_t session_generation=henge_vm_generation();
        struct stat original; check("saved file stats",!stat(snap,&original));
        CancelAtProgress cancellation={0};
        HvSnapshotControl control={.cancelled=cancel_at_progress,.progress=cancel_after_chunk,.context=&cancellation,.workers=1,.background=1};
        check("cancel mid-save leaves the original complete file",hv_snapshot_save_controlled(snap,"test",&control,error,sizeof error)!=0 &&
              strstr(error,"cancelled") && cancellation.scanned>0 && henge_vm_saved_ok(snap,"test",NULL,NULL)==0);
        struct stat after_cancel;check("cancellation does not replace the previous save",!stat(snap,&after_cancel) &&
              original.st_ino==after_cancel.st_ino && original.st_size==after_cancel.st_size);
        char partial[320];snprintf(partial,sizeof partial,"%s.part",snap);
        check("cancel removes only the partial file",access(partial,F_OK)!=0);
        saving_request=henge_vm_save_request(session_generation,1);saving_path=snap;
        if (!saving_request) return 1;
        save_gate_entered=save_gate_release=0;hv_snapshot_test_progress(save_gate);
        pthread_t saving_thread;if (pthread_create(&saving_thread,NULL,save_on_thread,NULL)) return 1;
        pthread_mutex_lock(&save_gate_mu);
        while (!save_gate_entered) pthread_cond_wait(&save_gate_cv,&save_gate_mu);
        pthread_mutex_unlock(&save_gate_mu);
        HengeSaveProgress saving;henge_vm_save_progress(saving_request,&saving);
        check("progress is readable without waiting for the VM save lock",saving.phase==1 && saving.scanned>0 && saving.scanned<=saving.total);
        henge_vm_save_cancel(saving_request);
        henge_vm_save_progress(saving_request,&saving);
        check("cancellation never waits for the snapshot writer",saving.cancelled);
        pthread_mutex_lock(&save_gate_mu);save_gate_release=1;pthread_cond_broadcast(&save_gate_cv);pthread_mutex_unlock(&save_gate_mu);
        pthread_join(saving_thread,NULL);hv_snapshot_test_progress(NULL);
        henge_vm_save_progress(saving_request,&saving);
        check("cancelled save returns paused without publishing partial state",save_result!=0 && saving.phase==3 &&
              henge_vm_state()==4 && henge_vm_saved_ok(snap,"test",NULL,NULL)==0 && access(partial,F_OK)!=0);
        check("save request is one shot",henge_vm_save_run(saving_request,snap,"test",error,sizeof error)!=0);
        henge_vm_save_free(saving_request);saving_request=NULL;
        char inspected_ident[1024];HengeSavedInfo saved_info;
        check("saved configuration can be inspected without allocating a VM",!henge_vm_saved_info(snap,inspected_ident,sizeof inspected_ident,&saved_info) &&
              !strcmp(inspected_ident,"test") && saved_info.ram_mb==64 && saved_info.cpus==2 && saved_info.bytes>0);
        check("stale generation cannot pause, resume or stop this Mac",
              henge_vm_pause_generation(session_generation+1,error,sizeof error)!=0 &&
              henge_vm_continue_generation(session_generation+1,snap,error,sizeof error)!=0 &&
              henge_vm_stop_generation(session_generation+1)!=0 && henge_vm_state()==4);
        check("failed saved-file invalidation keeps the Mac paused",henge_vm_continue_generation(session_generation,dir,error,sizeof error)!=0 &&
              henge_vm_state()==4 && strstr(error,"invalidated"));
        uint8_t released[8] = {0};
        check("pause releases all keys/modifiers", !memcmp(hv_vm_board()->usb->state, released, sizeof released));
        check("pause releases touch/button", !hv_vm_board()->usb->tp_button && !hv_vm_board()->usb->tp_fingers[0].in);
        HengeVmCounters paused;
        henge_vm_counters(&paused);
        check("paused counters retain VM totals", paused.state == 4 && paused.blocks > 0 &&
              paused.blocks == henge_vm_blocks() && paused.gpu_frames == henge_vm_gpu_frames() &&
              paused.tx == henge_vm_net_frames(1) && paused.rx == henge_vm_net_frames(0));
        HengeVmResources resources;henge_vm_resources(&resources);
        HengeGuestMemoryStatus allocated;henge_vm_guest_memory(&allocated);
        check("guest RAM status reports successful file backing while paused",allocated.state==4 && allocated.bytes==(64ull<<20) && allocated.backing==HV_RAM_FILE);
        check("resource diagnostics preserve lifetime and units", resources.generation==paused.generation && resources.epoch==paused.epoch &&
              resources.state==4 && (resources.available&11)==11 && resources.jit_capacity>0 && resources.jit_used<=resources.jit_capacity);
        volatile uint64_t *count = (volatile uint64_t *)hv_vm_board()->ram;
        uint64_t c1 = *count;
        usleep(200000); /* intentional delayed-resume coverage while CPUs are already paused */
        check("paused: the counter stands still", c1 > 0 && *count == c1);
        check("continue runs it on", henge_vm_continue() == 0 && henge_vm_state() == 1);
        check("prior-run deferred event cannot affect a continued Mac",hv_vm_test_network_apply(network_token,0)==0);
        if (getenv("HENGE_TEST_STATS")) stats_measure_run(); /* a different CPU0 thread */
        HengeVmCounters continued;
        henge_vm_counters(&continued);
        check("continue invalidates rate baseline without changing machine generation",
              continued.epoch > paused.epoch && continued.generation == paused.generation &&
              continued.blocks >= paused.blocks);
        for (int n = 0; n < 1000 && *count == c1; n++) usleep(1000);
        check("continued: the counter moves", *count > c1);
        check_cpu_identity();
        rc = henge_vm_suspend(snap, "test", error, sizeof error);
        if (rc || henge_vm_state() != 4 || !hv_vm_board()->ram) return 1;
        uint64_t c2 = *count;
        check("second suspend saves", rc == 0 && c2 > c1);
        HengeVmCounters second_pause;
        henge_vm_counters(&second_pause);
        check("second pause advances counter epoch", second_pause.epoch > continued.epoch);
        henge_vm_stop();
        HengeVmCounters stopped;
        henge_vm_counters(&stopped);
        check("stopped counters survive VM destruction", stopped.state == 2 &&
              stopped.epoch > second_pause.epoch && stopped.blocks == second_pause.blocks &&
              stopped.gpu_frames == second_pause.gpu_frames && stopped.tx == second_pause.tx && stopped.rx == second_pause.rx);
        check("a paused Mac stops", henge_vm_state() == 2 && hv_vm_board()->ram == NULL);
        check("destroyed network rejects pending callbacks",hv_vm_test_network_apply(hv_vm_test_network_token(),1)==0);
        henge_vm_guest_memory(&allocated);
        check("destroyed guest RAM status cannot retain an allocation",allocated.state==2 && !allocated.bytes && allocated.backing==HV_RAM_NONE);
        uint64_t bytes = 0;
        check("the save is whole", henge_vm_saved_ok(snap, "test", &bytes, NULL) == 0 && bytes > 0);
        check("another ident is refused", henge_vm_saved_ok(snap, "other", NULL, NULL) != 0);
        rc = henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, snap, "other", error, sizeof error);
        check("resume with another ident fails and leaves it startable", rc != 0 && henge_vm_can_start());
        check("failed resume preserves the complete saved state for recovery", access(snap, F_OK) == 0);
        char staged[1100];snprintf(staged,sizeof staged,"%s.using",snap);
        check("interrupted consumption retains a complete staged recovery",rename(snap,staged)==0);
        rc = henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, staged, "test", error, sizeof error);
        check("successful staged recovery consumes its file",access(staged,F_OK)!=0);
        if (rc) fprintf(stderr, "resume: %s\n", error);
        check("resume starts the saved Mac", rc == 0 && henge_vm_state() == 1);
        check("the file is used once", access(snap, F_OK) != 0);
        if (rc || henge_vm_state() != 1 || !hv_vm_board()->ram) return 1;
        count = (volatile uint64_t *)hv_vm_board()->ram;
        check("resumed: the counter is where it was", *count >= c2);
        for (int n = 0; n < 1000 && *count == c2; n++) usleep(1000);
        check("resumed: the counter moves on", *count > c2);
        henge_vm_stop();
        for (int n = 0; n < 3000 && henge_vm_state() != 2; n++) usleep(1000);
        check("resumed Mac stops", henge_vm_state() == 2);
        /* A disk written after the save: the saved Mac must not come back over it. */
        rc = henge_vm_boot(rom, disk, aux, 1, 0, 64, 2, error, sizeof error);
        usleep(30000);
        rc |= henge_vm_suspend(snap, "test", error, sizeof error);
        henge_vm_stop();
        int dfd = open(disk, O_WRONLY);
        check("disk changed", dfd >= 0 && pwrite(dfd, "x", 1, 4096) == 1);
        if (dfd >= 0) close(dfd);
        check("save before the disk changes", rc == 0);
        rc = henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, snap, "test", error, sizeof error);
        check("a changed disk refuses the saved Mac", rc != 0 && strstr(error, "disk has changed") != NULL);
        check("refused, it can start from cold", henge_vm_state() == 0 && henge_vm_can_start());
        unlink(snap);
        /* Repeat real pause/continue without depending on a timing sleep to enter
           pause; the API itself waits for CPU, disk and graphics quiescence. */
        if (henge_vm_boot(rom, disk, aux, 1, 0, 64, 2, error, sizeof error)) return 1;
        for (int cycle = 0; cycle < 8; cycle++) {
            if (henge_vm_suspend(snap, "test", error, sizeof error) || henge_vm_state() != 4) return 1;
            volatile uint64_t *paused_count = (volatile uint64_t *)hv_vm_board()->ram;
            uint64_t value = *paused_count;
            for (int n = 0; n < 10000; n++) if (*paused_count != value) return 1;
            check("repeated snapshot valid", henge_vm_saved_ok(snap, "test", NULL, NULL) == 0);
            if (henge_vm_continue()) return 1;
        }
        /* A real filesystem failure must preserve an existing good snapshot and
           leave the machine paused and resumable. No fake successful save. */
        char blocked[320]; snprintf(blocked, sizeof blocked, "%s.part", snap);
        unlink(blocked);
        if (mkdir(blocked, 0700)) return 1;
        rc = henge_vm_suspend(snap, "test", error, sizeof error);
        check("failed suspend reports error and resumes", rc != 0 && henge_vm_state() == 1);
        check("failed replacement preserves prior save", henge_vm_saved_ok(snap, "test", NULL, NULL) == 0);
        rmdir(blocked);
        write_file(blocked, "interrupted partial save", 24);
        check("running after failed save", henge_vm_state() == 1);
        if (henge_vm_suspend(snap, "test", error, sizeof error)) return 1;
        check("interrupted partial replaced completely", access(blocked, F_OK) != 0 &&
              henge_vm_saved_ok(snap, "test", NULL, NULL) == 0);
        int disk_fd = hv_vm_board()->root_blk->disk->fd;
        hv_vm_board()->root_blk->disk->fd = -1;
        rc = henge_vm_save(snap, "test", error, sizeof error);
        hv_vm_board()->root_blk->disk->fd = disk_fd;
        check("disk sync error refuses save", rc != 0 && strstr(error, "could not be synchronized"));
        check("disk sync failure preserves prior save", henge_vm_saved_ok(snap, "test", NULL, NULL) == 0);
        SaveAttempt attempts[2] = {{snap, -1}, {snap, -1}};
        pthread_t saves[2];
        if (pthread_create(&saves[0], NULL, save_together, &attempts[0]) ||
            pthread_create(&saves[1], NULL, save_together, &attempts[1])) return 1;
        pthread_join(saves[0], NULL); pthread_join(saves[1], NULL);
        check("concurrent saves serialize", !attempts[0].result && !attempts[1].result &&
              henge_vm_saved_ok(snap, "test", NULL, NULL) == 0);
        for (int allocation = 0; allocation < 7; allocation++) {
            hv_snapshot_test_fail_persistently(allocation);
            rc = henge_vm_save(snap, "test", error, sizeof error);
            hv_snapshot_test_fail_after(-1);
            check("allocation failure reported and stays paused", rc != 0 && henge_vm_state() == 4);
            check("allocation failure preserves good save", henge_vm_saved_ok(snap, "test", NULL, NULL) == 0);
            check("allocation failure removes partial save", access(blocked, F_OK) != 0);
        }
        /* A transient packing allocation failure retries with fewer workers;
           persistent failures above must still refuse and preserve the save. */
        unsigned recovered_allocations = 0, essential_failures = 0;
        for (int allocation = 0; allocation < 9; allocation++) {
            hv_snapshot_test_fail_after(allocation);
            rc = henge_vm_save(snap, "test", error, sizeof error);
            int retried = hv_snapshot_test_packing_retries();
            hv_snapshot_test_fail_after(-1);
            if (retried) {
                recovered_allocations++;
                check("transient packing allocation recovers with smaller batch", rc == 0 && henge_vm_state() == 4);
            } else {
                essential_failures++;
                check("essential allocation failure refuses save", rc != 0 && henge_vm_state() == 4);
            }
            check("allocation outcome retains a complete compatible save", henge_vm_saved_ok(snap,"test",NULL,NULL) == 0);
            check("allocation outcome removes partial save", access(blocked,F_OK) != 0);
        }
        check("both essential and recoverable allocations exercised", recovered_allocations && essential_failures);
        if (henge_vm_continue() || henge_vm_suspend(snap, "test", error, sizeof error)) return 1;
        henge_vm_stop();
        /* A payload byte changed without changing file length or trailer. */
        int corrupt = open(snap, O_RDWR); uint32_t header_bytes; uint8_t byte;
        if (corrupt < 0 || pread(corrupt, &header_bytes, 4, 12) != 4 ||
            pread(corrupt, &byte, 1, header_bytes + 16 + 64) != 1) return 1;
        byte ^= 0x40;
        if (pwrite(corrupt, &byte, 1, header_bytes + 16 + 64) != 1) return 1;
        close(corrupt);
        rc = henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, snap, "test", error, sizeof error);
        check("corrupt CPU payload rejected before execution", rc != 0 && henge_vm_can_start());
        if (henge_vm_boot(rom, disk, aux, 1, 0, 64, 2, error, sizeof error) ||
            henge_vm_suspend(snap, "test", error, sizeof error)) return 1;
        henge_vm_stop();
        /* Truncation and old schema must be rejected before starting CPUs. */
        int sf = open(snap, O_RDWR); uint32_t old = 1;
        if (sf < 0 || pwrite(sf, &old, sizeof old, 8) != sizeof old) return 1;
        close(sf);
        check("old snapshot schema rejected", henge_vm_saved_ok(snap, "test", NULL, NULL) != 0);
        rc = henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, snap, "test", error, sizeof error);
        check("old schema leaves cold boot available", rc != 0 && henge_vm_can_start() && strstr(error, "incompatible snapshot format"));
        write_file(snap, "HENGESN1", 8);
        check("truncated save rejected", henge_vm_saved_ok(snap, "test", NULL, NULL) != 0);
        rc = henge_vm_resume(rom, disk, aux, 1, 0, 64, 2, snap, "test", error, sizeof error);
        check("truncation leaves cold boot available", rc != 0 && henge_vm_can_start());
        unlink(snap);
    }
    hv_vm_destroy();
    atomic_store(&reader_done, 1);
    pthread_join(reader, NULL);
    hv_jit_region_close(&jit);
    unlink(rom); unlink(disk); unlink(aux); rmdir(dir);
    printf("VM lifecycle: 12 power cycles, 3 failed boots and a suspend/resume, %d failures\n", failures);
    return failures != 0;
}
