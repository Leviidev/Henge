import Foundation

private final class FakeSave: ResumeSaveWork, @unchecked Sendable {
    let entered=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
    private let lock=NSLock()
    private var flag=false
    let blocked:Bool
    let outcome:ResumeOutcome
    init(blocked:Bool=false,outcome:ResumeOutcome = .success) { self.blocked=blocked;self.outcome=outcome }
    func cancel() { lock.lock();flag=true;lock.unlock();finished.signal() }
    var cancelled:Bool { lock.lock();defer {lock.unlock()};return flag }
    func run()->ResumeOutcome {
        entered.signal()
        if blocked { precondition(finished.wait(timeout:.now()+5) == .success,"Cancellation never reached the active save") }
        return cancelled ? .cancelled : outcome
    }
    func progress()->ResumeProgress { ResumeProgress(scanned:32,total:64,cancelled:cancelled) }
}
private final class Fixture: @unchecked Sendable {
    private let lock=NSLock()
    var gen:UInt64=1,vm:Int32=1
    var pauses=0,resumes=0,stops=0,discards=0,builds=0,completions=0
    var pauseFails=false,discardFails=false,stopFails=false,file=true
    var save=FakeSave()
    var events:[ResumeEvent]=[]
    func access<T>(_ action:(Fixture)->T)->T { lock.lock();defer{lock.unlock()};return action(self) }
    func operations()->ResumeOperations {
        ResumeOperations(generation:{self.access{$0.gen}},state:{self.access{$0.vm}},
            pause:{_ in self.access { f in f.pauses+=1;if f.pauseFails{return .failure("pause failed")};f.vm=4;return .success }},
            resume:{_ in self.access { f in f.resumes+=1;f.file=false;f.vm=1;return .success }},
            stop:{_ in self.access{f in f.stops+=1;if f.stopFails{return .failure("stop failed")};f.vm=2;return .success}},
            discard:{_ in self.access{f in f.discards+=1;if f.discardFails{return .failure("cannot unlink")};f.file=false;return .success}},
            makeSave:{_,_ in self.access{f in f.builds+=1;return f.save}})
    }
    func coordinator()->ResumeCoordinator { ResumeCoordinator(operations:operations()){e in self.access{$0.events.append(e)}} }
    var session:ResumeSession { ResumeSession(generation:access{$0.gen},path:"/mac/resume.hsnap",ident:"saved actual configuration") }
}
private func identityChecks() throws {
    let build=ResumeBuildIdentity(version:"0.3.4",number:"105",source:String(repeating:"a",count:40),stamp:"2026-11-12")
    let id=UUID(),configuration=ResumeConfiguration(build:build,macID:id,ecid:UInt64.max,seed:7,ramMB:8192,cpus:4,width:2752,height:2064,retina:true,hz:120,mmWidth:260,mmHeight:195)
    let text=try configuration.encoded()
    precondition(text.utf8.count<1024)
    let restored=try ResumeConfiguration.decode(text,build:build,macID:id,ecid:UInt64.max,seed:7,ramMB:8192,cpus:4)
    let reencoded=try restored.encoded()
    precondition(restored == configuration && reencoded == text)
    // The launch chooses the saved configuration, not newly selected6CPU/6GB/60Hz preferences.
    precondition(restored.cpus==4 && restored.ramMB==8192 && restored.hz==120 && restored.retina)
    for bad in ["","Henge old human-readable identity",String(text.dropLast()),"HengeResume1:%%%",String(repeating:"a",count:2048)] {
        precondition((try? ResumeConfiguration.decode(bad,build:build,macID:id,ecid:UInt64.max,seed:7,ramMB:8192,cpus:4)) == nil)
    }
    precondition((try? ResumeConfiguration.decode(text,build:build,macID:UUID(),ecid:UInt64.max,seed:7,ramMB:8192,cpus:4)) == nil)
    precondition((try? ResumeConfiguration.decode(text,build:build,macID:id,ecid:UInt64.max,seed:7,ramMB:6144,cpus:4)) == nil)
    precondition((try? ResumeConfiguration.decode(text,build:build,macID:id,ecid:UInt64.max,seed:7,ramMB:8192,cpus:6)) == nil)
    let other=ResumeBuildIdentity(version:"0.3.4",number:"105",source:"another source",stamp:build.stamp)
    precondition((try? ResumeConfiguration.decode(text,build:other,macID:id,ecid:UInt64.max,seed:7,ramMB:8192,cpus:4)) == nil)
    precondition(restored.presentationScale == nil) // old snapshots keep native output
    var fx=ResumeConfiguration(build:build,macID:id,ecid:UInt64.max,seed:7,ramMB:8192,cpus:4,
        width:1280,height:960,retina:false,hz:60,mmWidth:0,mmHeight:0,presentationScale:2)
    let fxText=try fx.encoded()
    precondition(try! ResumeConfiguration.decode(fxText,build:build,macID:id,ecid:UInt64.max,seed:7,ramMB:8192,cpus:4).presentationScale == 2)
    fx.presentationScale=3;precondition((try? fx.encoded()) == nil)
    print("PASS Desktop MetalFX snapshot identity: native legacy default, exact 1x guest/2x output roundtrip and invalid scale rejection")
    let registry=ResumeRuntimeRegistry();registry.record(configuration,generation:10)
    let first=registry.claimView(),second=registry.claimView()
    precondition(!registry.ownsView(first) && registry.ownsView(second))
    precondition(!registry.releaseView(first) && registry.hasActiveView)
    precondition(registry.releaseView(second) && !registry.hasActiveView)

    precondition(registry.configuration(macID:id,generation:10,state:4)==configuration)
    precondition(registry.configuration(macID:id,generation:10,state:2)==nil)
    precondition(registry.configuration(macID:UUID(),generation:10,state:1)==nil)
    precondition(registry.configuration(macID:id,generation:11,state:1)==nil)
    registry.clear(generation:9);precondition(registry.owns(macID:id,generation:10))
    registry.clear(generation:10);precondition(!registry.owns(macID:id,generation:10))
}
@main struct Check {
    static func main() throws {
        try identityChecks()
        let ticket=ResumeTicket(revision:9,generation:2)
        var expired=ResumeLease(granted:true,required:true)
        precondition(expired.expire()==nil && expired.finish())
        precondition(expired.bind(ticket)==ticket && !expired.finish())
        var completed=ResumeLease(granted:true,required:true)
        precondition(completed.bind(ticket)==nil && completed.finish())
        precondition(completed.expire()==nil && !completed.expired && !completed.finish())
        var denied=ResumeLease(granted:false,required:true)
        precondition(denied.bind(ticket)==ticket)
        var manual=ResumeLease(granted:false,required:false)
        precondition(manual.bind(ticket)==nil && !manual.expired)

        // Foreground wins before a queued pause executes: no late pause after returning.
        do {
            let f=Fixture(),gate=DispatchSemaphore(value:0),c=f.coordinator()
            c.perform{precondition(gate.wait(timeout:.now()+5) == .success)}
            c.pause(generation:1);c.foreground(f.session);gate.signal();c.drain()
            precondition(f.pauses==0 && f.vm==1 && f.resumes==1)
        }
        // Foreground cancellation is immediate, not queued behind a blocked writer.
        do {
            let f=Fixture();f.save=FakeSave(blocked:true);let c=f.coordinator()
            let old=c.save(f.session,background:true){_ in f.access{$0.completions+=1}}!
            precondition(f.save.entered.wait(timeout:.now()+5) == .success)
            precondition(c.progress()?.scanned==32)
            c.foreground(f.session);precondition(f.save.cancelled);c.drain()
            precondition(f.vm==1 && f.resumes==1 && f.completions==1 && !c.accepts(old))
        }
        // Expiration before allocation still pauses the Mac but performs no save I/O.
        do {
            let f=Fixture(),gate=DispatchSemaphore(value:0),c=f.coordinator()
            c.perform{precondition(gate.wait(timeout:.now()+5) == .success)}
            let ticket=c.save(f.session,background:true)!
            c.cancelSave(ticket);gate.signal();c.drain()
            precondition(f.pauses==1 && f.vm==4 && f.builds==0 && f.events.last?.phase == .paused)
        }
        // Duplicate background notifications do not rewrite an unchanged paused machine.
        do {
            let f=Fixture(),c=f.coordinator()
            precondition(c.save(f.session,background:true) != nil)
            precondition(c.save(f.session,background:true) == nil);c.drain()
            precondition(c.save(f.session,background:true) == nil && f.builds==1)
            c.foreground(f.session);c.drain();precondition(f.vm==1)
            precondition(c.save(f.session,background:true) != nil);c.drain();precondition(f.builds==2)
        }
        // Inactive/app-switcher notifications never cancel the same background save.
        do {
            let f=Fixture();f.save=FakeSave(blocked:true);let c=f.coordinator()
            let ticket=c.save(f.session,background:true)!
            precondition(f.save.entered.wait(timeout:.now()+5) == .success)
            precondition(c.pause(generation:1) == nil && !f.save.cancelled && c.accepts(ticket))
            precondition(c.save(f.session,background:true) == nil)
            f.save.finished.signal();c.drain()
            precondition(c.pause(generation:1) == nil && c.save(f.session,background:true) == nil)
            precondition(f.builds==1 && f.pauses==1 && f.vm==4)
            c.foreground(f.session);c.drain();precondition(f.vm==1)
        }
        // A stale generation cannot touch a replacement Mac.
        do {
            let f=Fixture(),gate=DispatchSemaphore(value:0),c=f.coordinator()
            c.perform{precondition(gate.wait(timeout:.now()+5) == .success)}
            c.pause(generation:1);f.access{$0.gen=2};gate.signal();c.drain()
            precondition(f.pauses==0 && f.events.allSatisfy{$0.phase == .pausing})
        }
        // Save & Leave closes only after commit, preserving the persistent file.
        do {
            let f=Fixture(),c=f.coordinator()
            c.save(f.session,background:false,leave:true){left in precondition(left);f.access{$0.completions+=1}}
            c.drain();precondition(f.vm==2 && f.stops==1 && f.discards==0 && f.file && f.completions==1)
            c.foreground(f.session);c.drain();precondition(f.resumes==0)
        }
        // A closing failure keeps the committed save and permits recovery.
        do {
            let f=Fixture();f.stopFails=true;let c=f.coordinator()
            c.save(f.session,background:false,leave:true){left in precondition(!left)};c.drain()
            precondition(f.vm==4 && f.file && f.events.last?.phase == .failed("stop failed"))
            c.foreground(f.session);c.drain();precondition(f.resumes==1 && f.vm==1)
        }
        // Guest shutdown during a queued transition cannot leave the UI busy.
        do {
            let f=Fixture();f.vm=2;let c=f.coordinator()
            c.foreground(f.session);c.drain()
            precondition(f.events.last?.phase == .stopped && f.resumes==0)
        }
        // A failed save remains paused and can immediately continue in memory.
        do {
            let f=Fixture();f.save=FakeSave(outcome:.failure("disk full"));let c=f.coordinator()
            c.save(f.session,background:true);c.drain()
            precondition(f.vm==4 && f.file && f.events.last?.phase == .failed("disk full"))
            c.foreground(f.session);c.drain();precondition(f.vm==1 && !f.file)
        }
        do {
            let f=Fixture();f.pauseFails=true;let c=f.coordinator()
            c.save(f.session,background:false);c.drain();precondition(f.builds==0 && f.vm==1)
        }
        // Stop cancels a writer before waiting and discards only after it drains.
        do {
            let f=Fixture();f.save=FakeSave(blocked:true);let c=f.coordinator()
            c.save(f.session,background:true)
            precondition(f.save.entered.wait(timeout:.now()+5) == .success)
            c.stop(f.session){ok in precondition(ok);f.access{$0.completions+=1}};c.drain()
            precondition(f.save.cancelled && f.vm==2 && f.discards==1 && !f.file && f.completions==1)
        }
        do {
            let f=Fixture();f.vm=4;f.discardFails=true;let c=f.coordinator()
            c.stop(f.session){ok in precondition(!ok)};c.drain()
            precondition(f.vm==4 && f.file && f.stops==0)
        }
        // An expired assertion from an earlier request never cancels its successor.
        do {
            let f=Fixture(),c=f.coordinator()
            let old=c.save(f.session,background:true)!;c.drain();c.foreground(f.session);c.drain()
            f.save=FakeSave(blocked:true)
            c.save(f.session,background:true)
            precondition(f.save.entered.wait(timeout:.now()+5) == .success)
            c.cancelSave(old);precondition(!f.save.cancelled)
            c.foreground(f.session);c.drain();precondition(f.vm==1)
        }
        print("Resume coordinator: stale intents/generations, immediate cancellation, expiry-before-start, coalescing, save/leave, errors, stop, recovery configuration and reattachment passed")
    }
}
