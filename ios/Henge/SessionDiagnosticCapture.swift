import Foundation
import Combine

/// Consumes SessionView's existing maintenance waiter for a bounded capture
/// or an explicitly enabled test session. No extra timer or input contents.
@MainActor
final class SessionDiagnosticCapture: ObservableObject {
    @Published private(set) var active = false
    private var end = 0.0
    private(set) var nextDeadline: Double?
    private var previous: (Double,HengeVmCounters,HengeVmResources)?
    private(set) var continuous = false
    private let reports = NativeReportPump { henge_vm_log_cache() }
    private let samplingQueue = DispatchQueue(label:"henge.diagnostics.sample",qos:.utility)
    private var sampleRevision: UInt64 = 0
    private var samplePending: UInt64?

    func requestNativeReport() { reports.request() }
    func begin(continuous: Bool = false) {
        if active {
            if continuous { self.continuous=true;end = .infinity }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        sampleRevision &+= 1
        self.continuous=continuous
        active = true; end = continuous ? .infinity : now+30; nextDeadline = now; previous = nil
        henge_vm_capture_timing(1)
        HengeLog.log("capture", continuous ? "BEGIN continuous; aggregate process CPU, VM/JIT/memory/network/presentation; GPU durations are overlapping per-backend lifetimes, not utilization; instrumentation overhead enabled for testing" : "BEGIN 30s; aggregate process CPU, VM/JIT/memory/network/presentation; classic/Metal4 GPU buffer durations may overlap and exclude other GPU users; no per-access counters enabled")
        if continuous { HengeLog.log("capture","Continuous test diagnostics: entire visible session; stage timings and 50Hz hot-code sampling; instrumentation affects timing; pause/background boundaries are recorded") }
    }
    func stop() {
        guard active else { return }
        sampleRevision &+= 1
        active = false; continuous = false; nextDeadline = nil; previous = nil
        henge_vm_capture_timing(0)
        HengeLog.log("capture","END; share henge.log and henge-native.log; host presentation is not game FPS; no temperature/watts measurement")
    }
    func event(_ name: String) {
        guard active else { return }
        HengeLog.log("capture-event",name)
        nextDeadline = ProcessInfo.processInfo.systemUptime
    }
    func sample() {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= (nextDeadline ?? now) else { return }
        guard samplePending == nil else {
            // A delayed worker cannot leave a past deadline spinning the UI.
            if now>=end { stop() } else { nextDeadline=now+(continuous ? 10 : 5) }
            return
        }
        let revision = sampleRevision
        samplePending = revision
        nextDeadline = now+(continuous ? 10 : 5)
        // Resource reads include input-device mutexes and kernel accounting.
        // Never hold the main actor/display-link callbacks behind that work.
        samplingQueue.async { [weak self] in
            var observation = HengeVmObservation()
            let observed = henge_vm_try_observation(&observation) != 0
            var resources = HengeVmResources()
            // Process/system memory remains useful while a lifecycle writer
            // owns the VM. Resources uses a nonblocking VM read-lock itself.
            henge_vm_resources(&resources)
            let sampledAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                self?.acceptSample(revision:revision, observed:observed,
                                   observation:observation, resources:resources, now:sampledAt)
            }
        }
    }

    private func acceptSample(revision: UInt64, observed: Bool, observation: HengeVmObservation,
                              resources: HengeVmResources, now: TimeInterval) {
        if samplePending == revision { samplePending = nil }
        guard active, revision == sampleRevision else { return }
        HengeLog.log("capture-memory", "sampled_uptime_s=\(String(format:"%.3f",now)) footprint=\(resources.footprint) resident=\(resources.resident) process_headroom=\(resources.headroom) physical_ram=\(ProcessInfo.processInfo.physicalMemory) system_vm_available=\(resources.available & 128 != 0) free=\(resources.system_free) speculative=\(resources.system_speculative) purgeable=\(resources.system_purgeable) compressor=\(resources.system_compressed) wired=\(resources.system_wired) active=\(resources.system_active) inactive=\(resources.system_inactive) external=\(resources.system_external) internal=\(resources.system_internal) (raw system categories in bytes; categories can overlap; not an allocatable-RAM sum or process allowance)")
        guard observed else {
            previous=nil;nextDeadline=min(end,now+5)
            if now>=end { stop() }
            return
        }
        let vm = observation.counters
        guard vm.generation==resources.generation, vm.epoch==resources.epoch, vm.state==resources.state else {
            previous = nil; nextDeadline = min(end,now+5)
            HengeLog.log("capture","Lifecycle changed during sample; mixed VM statistics discarded")
            if now>=end { stop() }
            return
        }
        var rates = "baseline"
        if let (time,oldVM,old) = previous, now-time>=0.25 {
            let seconds = now-time
            if old.available & 1 != 0, resources.available & 1 != 0, resources.process_cpu_us >= old.process_cpu_us {
                rates = String(format:"cpu_core_equivalents=%.3f interval_s=%.3f",Double(resources.process_cpu_us-old.process_cpu_us)/1_000_000/seconds,seconds)
            } else { rates = "cpu=unavailable" }
            if vm.generation==oldVM.generation && vm.epoch==oldVM.epoch,
               vm.gpu_frames>=oldVM.gpu_frames,vm.blocks>=oldVM.blocks,vm.tx>=oldVM.tx,vm.rx>=oldVM.rx {
                rates += String(format:" blocks_s=%.0f host_presentations_s=%.2f tx=%llu rx=%llu",Double(vm.blocks-oldVM.blocks)/seconds,Double(vm.gpu_frames-oldVM.gpu_frames)/seconds,vm.tx-oldVM.tx,vm.rx-oldVM.rx)
                if old.available & 16 != 0, resources.available & 16 != 0, resources.replay_gpu_ns>=old.replay_gpu_ns,
                   resources.replay_gpu_completed>=old.replay_gpu_completed, resources.replay_gpu_unavailable>=old.replay_gpu_unavailable {
                    rates += String(format:" replay_gpu_ms=%.3f replay_gpu_commands=%llu gpu_timing_unavailable=%llu replay_gpu_scope=classic_only",Double(resources.replay_gpu_ns-old.replay_gpu_ns)/1_000_000,resources.replay_gpu_completed-old.replay_gpu_completed,resources.replay_gpu_unavailable-old.replay_gpu_unavailable)
                } else { rates += " replay_gpu_timing=unavailable_or_new_baseline" }
                if old.available & 32 != 0, resources.available & 32 != 0,
                   resources.metal4_gpu_ns >= old.metal4_gpu_ns,
                   resources.metal4_gpu_completed >= old.metal4_gpu_completed {
                    rates += String(format:" metal4_gpu_ms=%.3f metal4_gpu_commands=%llu metal4_scope=guest_plus_presentation",
                                    Double(resources.metal4_gpu_ns-old.metal4_gpu_ns)/1_000_000,
                                    resources.metal4_gpu_completed-old.metal4_gpu_completed)
                } else { rates += " metal4_gpu_timing=unavailable_or_new_baseline" }
            } else { rates += " vm_rates=new_epoch" }
        }
        if previous == nil || now-(previous?.0 ?? now)>=0.25 { previous = (now,vm,resources) }
        let power = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let hz = getenv("HV_HZ").map { String(cString:$0) } ?? "unknown"
        let policy = getenv("HV_CPU_POLICY").map { String(cString:$0) } ?? "unknown"
        HengeLog.log("capture", "\(rates) state=\(vm.state) generation=\(vm.generation) epoch=\(vm.epoch) lpm=\(power) thermal=\(thermal) guest_hz=\(hz) cpu_policy=\(policy) available_bits=\(resources.available) footprint=\(resources.footprint) resident=\(resources.resident) headroom=\(resources.headroom) metal_allocated=\(resources.metal_allocated) physical_ram=\(ProcessInfo.processInfo.physicalMemory) jit_used=\(resources.jit_used) jit_capacity=\(resources.jit_capacity) translations=\(resources.translations) resets=\(resources.full_flushes) pad_delivered=\(resources.gamepad_delivered) pad_coalesced=\(resources.gamepad_coalesced) pad_overflow=\(resources.gamepad_overflow) detailed_counters=\(resources.detailed_counters)")
        HengeLog.log("capture-input", "\(HardwareMouse.shared.scrollDiagnostics) mouse_delivered=\(resources.mouse_delivered) mouse_dropped=\(resources.mouse_dropped) mouse_queued=\(resources.mouse_queued) pointer_wanted=\(PointerLock.wanted) owner=\(LocalPointerInput.ownership.owner)")
        HengeLog.log("capture-touch", NativeTouchSurface.diagnostics)
        let root=resources.disk.0,aux=resources.disk.1
        HengeLog.log("capture-io","root_enabled=\(resources.disk_timing_enabled.0) requests=\(root.0) service_us=\(root.1) queue_us=\(root.2) flush_us=\(root.3) max_service_us=\(root.4) flush_count=\(root.5) aux_enabled=\(resources.disk_timing_enabled.1) requests=\(aux.0) service_us=\(aux.1) queue_us=\(aux.2) flush_us=\(aux.3) max_service_us=\(aux.4) flush_count=\(aux.5) flush_mode=\(getenv("HV_FLUSH").map { String(cString:$0) } ?? "unknown") (cumulative measured I/O; worker durations can overlap)")
        let preferences = UserDefaults.standard
        HengeLog.log("capture-policy","requested_hz=\(preferences.integer(forKey:EngineTuning.refreshKey)) presentation_cap=\(preferences.integer(forKey:"henge.perf.presentationCap")) power_aware=\(preferences.object(forKey:"henge.perf.lowPowerAware") as? Bool ?? true) link_connected=\(LinkHostService.shared.connected) controls_only=\(LinkHostService.shared.controlOnly) grouped=\(getenv("HV_GROUPS").map { String(cString:$0) } ?? "0") superblocks=\(getenv("HV_SUPERBLOCKS").map { String(cString:$0) } ?? "0") group_min=\(getenv("HV_GROUP_MIN").map { String(cString:$0) } ?? "2") tlb_layout=\(getenv("HV_TLBT").map { String(cString:$0) } ?? "1") addend_preload=\(getenv("HV_TLB_PRELOAD").map { String(cString:$0) } ?? "0")")
        // Presented-time histogram is enabled by this same bounded capture:
        // frame-presented p95/p99 include cursor and idle intervals, not game FPS.
        // Existing cumulative wait/idle/cache reports, only during this capture.
        // Disabled per-access diagnostics remain explicitly unavailable.
        requestNativeReport()
        nextDeadline = min(end,now+(continuous ? 10 : 5))
        if now>=end { stop() }
    }
}
