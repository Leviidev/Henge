import UIKit
import AVFAudio

/// Event-driven recovery for the existing virtio-snd/RemoteIO backend. A retry
/// belongs to one VM generation; route changes never force the speaker output.
@MainActor final class AudioSessionRecovery {
    static let shared=AudioSessionRecovery()
    private var observers:[NSObjectProtocol]=[]
    private let work=DispatchQueue(label:"henge.audio.recovery",qos:.utility)
    private var pending:DispatchWorkItem?
    private var revision=UUID()
    private var interrupted=false
    private var route=""
    func start() {
        guard observers.isEmpty else { return }
        configureCategory()
        let center=NotificationCenter.default
        func observe(_ name:Notification.Name,_ action:@escaping @MainActor (Notification)->Void) {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { notification in
                MainActor.assumeIsolated { action(notification) }
            })
        }
        observe(AVAudioSession.interruptionNotification) { [weak self] notification in
            guard let self,let value=notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type=AVAudioSession.InterruptionType(rawValue:value) else { return }
            self.interrupted=type == .began
            if self.interrupted {
                self.cancel();let generation=henge_vm_generation()
                self.work.async { _=henge_vm_audio_event(generation,0) }
                HengeLog.log("audio","Output interrupted; guest audio clock retained")
            } else {
                let options=AVAudioSession.InterruptionOptions(rawValue:notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if options.contains(.shouldResume) { self.recover(reason:"interruption ended") }
            }
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] _ in
            guard let self else { return }
            let signature=self.routeSignature
            guard signature != self.route else { return }
            self.route=signature;self.recover(reason:"output route changed")
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { [weak self] _ in
            self?.interrupted=true;self?.cancel();HengeLog.log("audio","Audio services unavailable; waiting for reset")
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            self?.interrupted=false;self?.configureCategory();self?.recover(reason:"audio services reset")
        }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in self?.recover(reason:"foreground") }
        route=routeSignature
    }
    private var routeSignature:String {
        let session=AVAudioSession.sharedInstance()
        return session.currentRoute.outputs.map { $0.uid }.joined(separator:"|")+"/\(session.sampleRate)/\(session.outputNumberOfChannels)"
    }
    private func configureCategory() {
        let session=AVAudioSession.sharedInstance()
        guard session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) else { return }
        do { try session.setCategory(.playback,options:[.mixWithOthers]) }
        catch { HengeLog.log("audio","Cannot configure output: \(error.localizedDescription)") }
    }
    private func cancel() { revision=UUID();pending?.cancel();pending=nil }
    func recover(reason:String="manual") {
        guard !interrupted,henge_vm_state()==1 else { return }
        cancel();let current=revision,generation=henge_vm_generation()
        attempt(reason:reason,generation:generation,revision:current,index:0)
    }
    private func attempt(reason:String,generation:UInt64,revision current:UUID,index:Int) {
        guard revision==current,!interrupted,henge_vm_state()==1,henge_vm_generation()==generation else { return }
        configureCategory()
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { retry(reason:reason,generation:generation,revision:current,index:index);return }
        route=routeSignature
        work.async { [weak self] in
            let result=henge_vm_audio_event(generation,1)
            Task { @MainActor in
                guard let self,self.revision==current else { return }
                if result==0 { HengeLog.log("audio","Output recovered after \(reason); existing guest stream preserved") }
                else { self.retry(reason:reason,generation:generation,revision:current,index:index) }
            }
        }
    }
    private func retry(reason:String,generation:UInt64,revision current:UUID,index:Int) {
        let delays=[0.25,1.0,3.0]
        guard index<delays.count else { HengeLog.log("audio","Output recovery paused; use Recover sound from the three-finger menu");return }
        let task=DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.attempt(reason:reason,generation:generation,revision:current,index:index+1) }
        }
        pending=task;DispatchQueue.main.asyncAfter(deadline:.now()+delays[index],execute:task)
    }
}
