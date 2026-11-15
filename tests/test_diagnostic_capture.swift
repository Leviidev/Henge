import Foundation

private final class CaptureState: @unchecked Sendable {
    let lock=NSLock(), release=DispatchSemaphore(value:0)
    private var reads=0
    private var systemAvailable=true
    private var observationAvailable=true
    var logs:[String]=[]
    var timing:[Int32]=[]
    func read(_ output:inout HengeVmResources) {
        precondition(!Thread.isMainThread)
        lock.lock();reads+=1;let n=reads,system=systemAvailable;lock.unlock()
        if n==1 {precondition(release.wait(timeout:.now()+5) == .success)}
        output.generation=1;output.epoch=1;output.state=1;output.available=system ? 255 : 127
        output.process_cpu_us=UInt64(n)*1_000_000;output.replay_gpu_ns=UInt64(n)*1_000_000
        output.replay_gpu_completed=UInt64(n);output.metal4_gpu_ns=UInt64(n)*10_000_000
        output.metal4_gpu_completed=UInt64(n);output.metal_allocated=123456
        output.headroom=UInt64(n)*1000
        if system {output.system_free=4096;output.system_compressed=8192}
    }
    var count:Int {lock.lock();defer{lock.unlock()};return reads}
    func restrictSystemRead(){lock.lock();systemAvailable=false;lock.unlock()}
    func restrictVMObservation(){lock.lock();observationAvailable=false;lock.unlock()}
    var observed:Bool {lock.lock();defer{lock.unlock()};return observationAvailable}
}
private let fixture=CaptureState()
struct HengeVmCounters {var generation:UInt64=0,epoch:UInt64=0,blocks:UInt64=0,gpu_frames:UInt64=0,tx:UInt64=0,rx:UInt64=0;var state:Int32=0}
struct HengeVmObservation {var counters=HengeVmCounters();var cpus_on:Int32=0,guest_el0:Int32=0}
struct HengeVmResources {
    var process_cpu_us:UInt64=0,footprint:UInt64=0,resident:UInt64=0,headroom:UInt64=0,jit_used:UInt64=0,jit_capacity:UInt64=0,translations:UInt64=0,full_flushes:UInt64=0
    var gamepad_delivered:UInt64=0,gamepad_coalesced:UInt64=0,gamepad_overflow:UInt64=0
    var mouse_delivered:UInt64=0,mouse_dropped:UInt64=0,mouse_queued:UInt64=0
    var replay_gpu_completed:UInt64=0,replay_gpu_ns:UInt64=0,replay_gpu_max_ns:UInt64=0,replay_gpu_unavailable:UInt64=0
    var metal_allocated:UInt64=0,metal4_gpu_completed:UInt64=0,metal4_gpu_ns:UInt64=0,metal4_gpu_max_ns:UInt64=0
    var system_free:UInt64=0,system_speculative:UInt64=0,system_purgeable:UInt64=0,system_compressed:UInt64=0
    var system_wired:UInt64=0,system_active:UInt64=0,system_inactive:UInt64=0,system_external:UInt64=0,system_internal:UInt64=0
    var disk=((UInt64(0),UInt64(0),UInt64(0),UInt64(0),UInt64(0),UInt64(0)),(UInt64(0),UInt64(0),UInt64(0),UInt64(0),UInt64(0),UInt64(0)))
    var disk_timing_enabled=(Int32(0),Int32(0));var detailed_counters:Int32=0
    var available:UInt32=0,generation:UInt64=0,epoch:UInt64=0;var state:Int32=0
}
func henge_vm_capture_timing(_ on:Int32){fixture.timing.append(on)}
func henge_vm_try_observation(_ out:inout HengeVmObservation)->Int32 {
    precondition(!Thread.isMainThread)
    out.counters.generation=1;out.counters.epoch=1;out.counters.state=1;return fixture.observed ? 1 : 0
}
func henge_vm_resources(_ out:inout HengeVmResources){fixture.read(&out)}
func henge_vm_log_cache(){precondition(!Thread.isMainThread)}
enum HengeLog {static func log(_ tag:String,_ message:String){fixture.logs.append(tag+":"+message)}}
struct HardwareMouse {static let shared=HardwareMouse();let scrollDiagnostics="wheel callbacks=0"}
enum NativeTouchSurface {static let diagnostics="touch idle"}
enum LocalPointerInput {struct Owner {let owner="none"};static let ownership=Owner()}
enum PointerLock {static let wanted=false}
enum EngineTuning {static let refreshKey="henge.test.capture.refresh"}
struct LinkHostService {static let shared=LinkHostService();let connected=false,controlOnly=false}
@main struct Check {
    @MainActor static func until(_ stage:String,_ predicate:()->Bool) async {
        for _ in 0..<2000 {
            if predicate() {return}
            try? await Task.sleep(nanoseconds:1_000_000)
        }
        preconditionFailure("Diagnostic capture timed out: \(stage); reads=\(fixture.count); timing=\(fixture.timing); logs=\(fixture.logs.suffix(8))")
    }
    @MainActor static func main() async {
        let capture=SessionDiagnosticCapture()
        capture.begin(continuous:true);capture.sample()
        await until("first off-main read") {fixture.count==1}
        precondition(fixture.count==1)
        // A blocked native mutex cannot block the main actor or enqueue 100
        // reads. Stop/start invalidates the result, not the native VM memory.
        for _ in 0..<100 {capture.event("input");capture.sample()}
        precondition(fixture.count==1)
        var uiRan=false;await Task { @MainActor in uiRan=true }.value;precondition(uiRan)
        capture.stop();capture.begin(continuous:true)
        capture.sample();precondition(fixture.count==1)
        fixture.release.signal()
        // A fresh request is admitted only after the stale completion has been
        // rejected. Verify the emitted baseline belongs to native read 2.
        await until("fresh baseline after stale rejection") {
            // Stop issuing work once read 2 enters. Otherwise a completed
            // read 2 can admit read 3 before this polling task checks count.
            if fixture.count<2 {capture.event("fresh");capture.sample()}
            return fixture.logs.contains{$0.contains("metal_allocated=123456")}
        }
        precondition(fixture.count==2)
        precondition(fixture.logs.filter{$0.contains("state=1 generation=1")}.count==1)
        // The stale background read must not turn capture timing back on.
        precondition(fixture.timing==[1,0,1])
        precondition(fixture.logs.contains{$0.contains("metal_allocated=123456")})
        precondition(fixture.logs.contains{$0.contains("system_vm_available=true free=4096") && $0.contains("compressor=8192")})
        // The second accepted sample provides interval deltas, kept separate.
        try? await Task.sleep(nanoseconds:300_000_000)
        capture.event("fresh2");capture.sample()
        await until("separate backend interval deltas") {fixture.logs.contains{$0.contains("replay_gpu_scope=classic_only") && $0.contains("metal4_gpu_ms=10.000")}}
        fixture.restrictSystemRead()
        try? await Task.sleep(nanoseconds:300_000_000)
        capture.event("system_access_restricted");capture.sample()
        await until("restricted system counters labelled unavailable") {fixture.logs.contains{$0.contains("system_vm_available=false")}}
        let beforeVM=fixture.logs.filter{$0.contains("state=1 generation=1")}.count
        fixture.restrictVMObservation()
        try? await Task.sleep(nanoseconds:300_000_000)
        capture.event("lifecycle_writer");capture.sample()
        await until("process memory survives a busy lifecycle writer") {fixture.logs.contains{$0.contains("capture-memory:") && $0.contains("process_headroom=5000")}}
        precondition(fixture.logs.filter{$0.contains("state=1 generation=1")}.count==beforeVM)
        capture.stop();precondition(fixture.timing==[1,0,1,0])
        print("PASS production capture: off-main native reads, bounded admission, stale stop/restart rejection, no timing resurrection and separate classic/Metal4 deltas")
        print("PASS production memory capture: raw system categories, restricted-read availability and process memory during VM lifecycle writers without mixed VM rates")
    }
}
