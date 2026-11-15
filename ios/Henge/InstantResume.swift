import Foundation
import Combine
import UIKit

@MainActor
final class InstantResumeStatus: ObservableObject {
    static let shared = InstantResumeStatus()
    @Published var phase = ResumePhase.idle
    @Published var progress = ResumeProgress()
    @Published var generation: UInt64 = 0
    var busy: Bool { [.pausing,.saving,.resuming,.closing,.stopping].contains(phase) }
}

/// Owns its assertion only on main. Completion and expiry can arrive in either
/// order; expiry cancels the exact request, never a newer session's save.
@MainActor
private final class ResumeBackgroundAssertion {
    private var task = UIBackgroundTaskIdentifier.invalid
    private var lease = ResumeLease(granted:true,required:false)
    init(required: Bool) {
        task = UIApplication.shared.beginBackgroundTask(withName:"Save Mac session") { [weak self] in
            Task { @MainActor [weak self] in self?.expire() }
        }
        lease=ResumeLease(granted:task != .invalid,required:required)
    }
    func bind(_ ticket: ResumeTicket?) {
        if let cancelled=lease.bind(ticket) { InstantResume.coordinator.cancelSave(cancelled) }
    }
    private func expire() {
        if let ticket=lease.expire() { InstantResume.coordinator.cancelSave(ticket) }
        finish()
    }
    func finish() {
        guard lease.finish() else { return }
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }
}

private final class NativeResumeSave: ResumeSaveWork, @unchecked Sendable {
    private let request: OpaquePointer
    private let session: ResumeSession
    init?(_ session: ResumeSession, background: Bool) {
        guard let request = henge_vm_save_request(session.generation,background ? 1 : 0) else { return nil }
        self.request = request; self.session = session
    }
    deinit { henge_vm_save_free(request) }
    func cancel() { henge_vm_save_cancel(request) }
    func run() -> ResumeOutcome {
        let outcome = InstantResume.nativeResult { henge_vm_save_run(request,session.path,session.ident,$0,$1) }
        var status = HengeSaveProgress(); henge_vm_save_progress(request,&status)
        return status.phase == 3 ? .cancelled : outcome
    }
    func progress() -> ResumeProgress {
        var status = HengeSaveProgress(); henge_vm_save_progress(request,&status)
        return ResumeProgress(scanned:status.scanned,total:status.total,cancelled:status.cancelled != 0)
    }
}

enum InstantResume {
    static let runtime=ResumeRuntimeRegistry()
    static let key = "henge.instantResume"
    static var enabled: Bool { UserDefaults.standard.object(forKey:key) as? Bool ?? true }
    static var buildIdentity: ResumeBuildIdentity {
        let i=Bundle.main.infoDictionary ?? [:]
        return ResumeBuildIdentity(version:i["CFBundleShortVersionString"] as? String ?? "?",
            number:i["CFBundleVersion"] as? String ?? "?",
            source:i["HengeCustomSourceCommit"] as? String ?? i["HengeBuildCommit"] as? String ?? "unstamped",
            stamp:i["HengeBuildDate"] as? String ?? "?")
    }
    static let coordinator: ResumeCoordinator = ResumeCoordinator(operations:ResumeOperations(
        generation:{henge_vm_generation()},state:{henge_vm_state()},
        pause:{generation in nativeResult { henge_vm_pause_generation(generation,$0,$1) }},
        resume:{session in nativeResult { henge_vm_continue_generation(session.generation,session.path,$0,$1) }},
        stop:{generation in henge_vm_stop_generation(generation) == 0 ? .success : .failure("The Mac session changed.")},
        discard:{session in
            guard henge_vm_generation() == session.generation else { return .cancelled }
            do {
                for path in [session.path,session.path+".part",session.path+".using"] where FileManager.default.fileExists(atPath:path) {
                    try FileManager.default.removeItem(atPath:path)
                }
                return .success
            } catch { return .failure("The old saved state could not be removed: \(error.localizedDescription)") }
        },
        makeSave:{session,background in NativeResumeSave(session,background:background)}
    )) { event in publish(event) }

    private static func publish(_ event:ResumeEvent) {
        DispatchQueue.main.async {
            guard coordinator.accepts(event.ticket),henge_vm_generation() == event.ticket.generation else { return }
            let status=InstantResumeStatus.shared
            status.generation=event.ticket.generation;status.phase=event.phase
            if event.phase != .saving { status.progress=ResumeProgress() }
            HengeLog.log("resume","generation=\(event.ticket.generation) request=\(event.ticket.revision) phase=\(event.phase)")
        }
    }

    static func nativeResult(_ operation:(UnsafeMutablePointer<CChar>,Int)->Int32) -> ResumeOutcome {
        var error=[CChar](repeating:0,count:512)
        return operation(&error,error.count) == 0 ? .success : .failure(String(cString:error))
    }
    static func file(for mac:VirtualMac)->URL { mac.directory.appendingPathComponent("resume.hsnap") }
    private static func savedFile(for mac:VirtualMac)->URL {
        let primary=file(for:mac)
        return FileManager.default.fileExists(atPath:primary.path) ? primary : mac.directory.appendingPathComponent("resume.hsnap.using")
    }
    static func hasSave(for mac:VirtualMac)->Bool { FileManager.default.fileExists(atPath:savedFile(for:mac).path) }
    static func configuration(for mac:VirtualMac) throws -> ResumeConfiguration? {
        guard hasSave(for:mac) else { return nil }
        var text=[CChar](repeating:0,count:1024),info=HengeSavedInfo()
        guard henge_vm_saved_info(savedFile(for:mac).path,&text,text.count,&info) == 0 else { throw ResumeIdentityError.invalid }
        return try ResumeConfiguration.decode(String(cString:text),build:buildIdentity,macID:mac.id,ecid:mac.ecid,seed:mac.seed,
                                               ramMB:info.ram_mb,cpus:Int(info.cpus))
    }
    static func identity(for mac:VirtualMac,ramMB:UInt64,cpus:Int,hz:Int,mmWidth:Int,mmHeight:Int)->ResumeConfiguration {
        ResumeConfiguration(build:buildIdentity,macID:mac.id,ecid:mac.ecid,seed:mac.seed,ramMB:ramMB,cpus:cpus,
            width:mac.screenWidth ?? 1920,height:mac.screenHeight ?? 1080,retina:mac.isRetina,hz:hz,mmWidth:mmWidth,mmHeight:mmHeight,
            presentationScale:mac.usesDesktopMetalFX ? 2 : nil)
    }
    private static func session(_ mac:VirtualMac,ident:String="")->ResumeSession {
        ResumeSession(generation:henge_vm_generation(),path:file(for:mac).path,ident:ident)
    }
    /// Autosave preference controls future automatic pauses. An existing saved
    /// session is still honoured when that preference is turned off.
    static func start(_ mac:VirtualMac,configuration:ResumeConfiguration,restore:Bool) async -> (Int32,String) {
        let rom=mac.rom.path,disk=mac.disk.path,aux=mac.aux.path,path=savedFile(for:mac).path
        return await withCheckedContinuation { continuation in
            coordinator.perform {
                var buffer=[CChar](repeating:0,count:512)
                let rc:Int32
                if restore {
                    guard let ident=try? configuration.encoded() else {
                        continuation.resume(returning:(-1,ResumeIdentityError.invalid.localizedDescription));return
                    }
                    rc=henge_vm_resume(rom,disk,aux,mac.ecid,mac.seed,configuration.ramMB,Int32(configuration.cpus),path,ident,&buffer,buffer.count)
                } else {
                    if hasSave(for:mac) { continuation.resume(returning:(-1,"A saved state appeared before startup. Open this Mac again to restore it."));return }
                    rc=henge_vm_boot(rom,disk,aux,mac.ecid,mac.seed,configuration.ramMB,Int32(configuration.cpus),&buffer,buffer.count)
                }
                if rc == 0 { runtime.record(configuration,generation:henge_vm_generation()) }
                continuation.resume(returning:(rc,String(cString:buffer)))
            }
        }
    }
    @discardableResult static func discard(for mac:VirtualMac) -> Bool {
        for path in [file(for:mac).path,file(for:mac).path+".part",file(for:mac).path+".using"] where FileManager.default.fileExists(atPath:path) {
            do { try FileManager.default.removeItem(atPath:path) }
            catch { HengeLog.log("resume","Could not discard saved state: \(error.localizedDescription)"); return false }
        }
        return true
    }
    static func pause(force:Bool=false,generation:UInt64?=nil,completion:(()->Void)?=nil) {
        guard enabled || force else { completion?();return }
        coordinator.pause(generation:generation ?? henge_vm_generation()) { completion?() }
    }
    @MainActor static func suspend(_ mac:VirtualMac,configuration:ResumeConfiguration,leave:Bool=false,completion:@escaping(Bool)->Void={_ in}) {
        guard enabled || leave else { completion(false);return }
        let generation=henge_vm_generation()
        guard runtime.configuration(macID:mac.id,generation:generation,state:henge_vm_state()) == configuration else { completion(false);return }
        guard let ident=try? configuration.encoded() else { InstantResumeStatus.shared.phase = .failed("The session configuration could not be saved.");completion(false);return }
        let assertion=ResumeBackgroundAssertion(required:!leave)
        let current=ResumeSession(generation:generation,path:file(for:mac).path,ident:ident)
        let ticket=coordinator.save(current,background:!leave,leave:leave) { left in
            if left { runtime.clear(generation:current.generation) }
            DispatchQueue.main.async { assertion.finish();completion(left) }
        }
        assertion.bind(ticket)
    }
    static func cameBack(_ mac:VirtualMac) {
        let current=session(mac)
        guard runtime.owns(macID:mac.id,generation:current.generation) else { return }
        coordinator.foreground(current)
    }
    static func stop(_ mac:VirtualMac,completion:@escaping(Bool)->Void) {
        let current=session(mac)
        guard runtime.owns(macID:mac.id,generation:current.generation) else { completion(false);return }
        coordinator.stop(current) { stopped in
            if stopped { runtime.clear(generation:current.generation) }
            DispatchQueue.main.async { completion(stopped) }
        }
    }
    @MainActor static func updateProgress() {
        if let progress=coordinator.progress() { InstantResumeStatus.shared.progress=progress }
    }
}
