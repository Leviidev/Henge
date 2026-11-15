import Foundation

struct ResumeSession: Equatable, Sendable {
    let generation: UInt64
    let path: String
    let ident: String
}

enum ResumeOutcome: Equatable, Sendable {
    case success, cancelled, failure(String)
}

struct ResumeProgress: Sendable {
    var scanned: UInt64 = 0
    var total: UInt64 = 0
    var cancelled = false
}

protocol ResumeSaveWork: AnyObject, Sendable {
    func cancel()
    func run() -> ResumeOutcome
    func progress() -> ResumeProgress
}

struct ResumeOperations: @unchecked Sendable {
    let generation: () -> UInt64
    let state: () -> Int32
    let pause: (UInt64) -> ResumeOutcome
    let resume: (ResumeSession) -> ResumeOutcome
    let stop: (UInt64) -> ResumeOutcome
    let discard: (ResumeSession) -> ResumeOutcome
    let makeSave: (ResumeSession, Bool) -> ResumeSaveWork?
}

struct ResumeTicket: Equatable, Sendable {
    let revision: UInt64
    let generation: UInt64
}

enum ResumePhase: Equatable, Sendable {
    case idle, pausing, paused, saving, saved, resuming, running, closing, stopping, stopped
    case failed(String)
}

struct ResumeEvent: Sendable {
    let ticket: ResumeTicket
    let phase: ResumePhase
}

/// One transition queue; intent/cancellation never waits on a native snapshot.
/// Native calls independently verify generation under their VM lock.
final class ResumeCoordinator: @unchecked Sendable {
    private enum Intent: Equatable { case pause, save(ResumeSession, Bool), foreground, stop, closing }
    private let queue = DispatchQueue(label: "henge.instant-resume", qos: .userInitiated)
    private let lock = NSLock()
    private let ops: ResumeOperations
    private let notify: (ResumeEvent) -> Void
    private var revision: UInt64 = 0
    private var latest: ResumeTicket?
    private var intent: Intent?
    private var work: ResumeSaveWork?
    private var completedSave: ResumeSession?
    private var saveCancelled = false
    private var savePending = false

    init(operations: ResumeOperations, notify: @escaping (ResumeEvent) -> Void) {
        ops = operations; self.notify = notify
    }

    func accepts(_ ticket: ResumeTicket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return latest == ticket
    }

    private func submit(_ next: Intent, generation: UInt64) -> ResumeTicket? {
        guard generation > 0 else { return nil }
        lock.lock()
        if latest?.generation == generation && intent == .closing { lock.unlock(); return nil }
        // Returning through inactive, or revisiting the app switcher, must not
        // cancel a running save or cause a completed unchanged VM to be saved
        // again. Foreground/resume and explicit stop still supersede it.
        if next == .pause, latest?.generation == generation, case .save = intent {
            lock.unlock(); return nil
        }
        if case .save(let session, false) = next, intent == next,
           !saveCancelled && (savePending || work != nil || completedSave == session) { lock.unlock(); return nil }
        revision &+= 1
        let ticket = ResumeTicket(revision: revision, generation: generation)
        let previous = work
        work = nil; latest = ticket; intent = next; saveCancelled = false
        if case .save = next { savePending = true } else { savePending = false }
        if next == .foreground || next == .stop { completedSave = nil }
        lock.unlock()
        previous?.cancel() // lock-free native cancellation, not queued behind I/O
        return ticket
    }

    private func current(_ ticket: ResumeTicket) -> Bool {
        accepts(ticket) && ops.generation() == ticket.generation
    }

    private func live(_ ticket:ResumeTicket)->Bool {
        guard current(ticket) else {return false}
        let state=ops.state()
        guard state==1 || state==4 else {
            publish(state==0 || state==2 ? .stopped : .failed("The Mac is in another lifecycle transition."),ticket)
            return false
        }
        return true
    }

    private func publish(_ phase: ResumePhase, _ ticket: ResumeTicket) {
        if current(ticket) { notify(ResumeEvent(ticket: ticket, phase: phase)) }
    }

    @discardableResult func pause(generation: UInt64, completion: @escaping () -> Void = {}) -> ResumeTicket? {
        guard let ticket = submit(.pause, generation: generation) else { completion(); return nil }
        publish(.pausing,ticket)
        queue.async {
            defer { completion() }
            guard self.live(ticket) else { return }
            self.publish(.pausing, ticket)
            let outcome = self.ops.state() == 4 ? .success : self.ops.pause(generation)
            switch outcome {
            case .success: self.publish(.paused, ticket)
            case .cancelled: break
            case .failure(let reason): self.publish(.failed(reason), ticket)
            }
        }
        return ticket
    }

    @discardableResult func save(_ session: ResumeSession, background: Bool, leave: Bool = false,
                                 completion: @escaping (Bool) -> Void = { _ in }) -> ResumeTicket? {
        guard let ticket = submit(.save(session, leave), generation: session.generation) else { completion(false); return nil }
        publish(.pausing,ticket)
        queue.async {
            var left = false
            defer {
                self.lock.lock(); if self.latest == ticket { self.savePending = false }; self.lock.unlock()
                completion(left)
            }
            guard self.current(ticket) else { return }
            if self.ops.state() == 1 {
                self.publish(.pausing, ticket)
                if case .failure(let reason) = self.ops.pause(session.generation) { self.publish(.failed(reason), ticket); return }
            }
            guard self.live(ticket), self.ops.state() == 4 else { return }
            self.lock.lock(); let cancelled = self.latest == ticket && self.saveCancelled; self.lock.unlock()
            if cancelled { self.publish(.paused,ticket); return }
            guard let job = self.ops.makeSave(session, background) else {
                self.publish(.failed("Not enough memory to prepare a save. The Mac is paused in memory."), ticket); return
            }
            self.lock.lock()
            let valid = self.latest == ticket && !self.saveCancelled
            if valid { self.work = job }
            self.lock.unlock()
            guard valid else { job.cancel(); self.publish(.paused,ticket); return }
            self.publish(.saving, ticket)
            let outcome = job.run()
            self.lock.lock()
            if self.latest == ticket { self.work = nil }
            self.lock.unlock()
            guard self.current(ticket) else { return }
            switch outcome {
            case .cancelled: self.publish(.paused, ticket)
            case .failure(let reason): self.publish(.failed(reason), ticket)
            case .success:
                self.lock.lock()
                let valid = self.latest == ticket
                if valid { self.completedSave = session; if leave { self.intent = .closing } }
                self.lock.unlock()
                guard valid else { return }
                if leave {
                    // Committing Save & Leave wins over a later automatic scene
                    // notification. Before this point, return/cancel wins.
                    self.publish(.closing, ticket)
                    switch self.ops.stop(session.generation) {
                    case .success: left = true; self.publish(.stopped, ticket)
                    case .failure(let reason):
                        self.lock.lock(); if self.latest == ticket { self.intent = .pause }; self.lock.unlock()
                        self.publish(.failed(reason), ticket)
                    case .cancelled:
                        self.lock.lock(); if self.latest == ticket { self.intent = .pause }; self.lock.unlock()
                    }
                } else { self.publish(.saved, ticket) }
            }
        }
        return ticket
    }

    func cancelSave(_ ticket: ResumeTicket) {
        lock.lock()
        let job = latest == ticket ? work : nil
        if latest == ticket { saveCancelled = true }
        lock.unlock()
        job?.cancel()
        // Expiration can precede request allocation. A cancelled intent must
        // also prevent a queued or paused-but-not-yet-saving job from starting.
    }

    func foreground(_ session: ResumeSession) {
        guard let ticket = submit(.foreground, generation:session.generation) else { return }
        publish(.resuming,ticket)
        queue.async {
            guard self.current(ticket) else { return }
            self.publish(.resuming,ticket)
            guard self.live(ticket) else { return }
            switch self.ops.resume(session) {
            case .success: self.publish(.running,ticket)
            case .failure(let reason): self.publish(.failed(reason),ticket)
            case .cancelled: break
            }
        }
    }

    func stop(_ session: ResumeSession, completion: @escaping (Bool) -> Void) {
        guard let ticket = submit(.stop, generation:session.generation) else { completion(false); return }
        publish(.stopping,ticket)
        queue.async {
            var stopped = false
            defer { completion(stopped) }
            guard self.current(ticket) else { return }
            self.publish(.stopping,ticket)
            switch self.ops.discard(session) {
            case .success: break
            case .failure(let reason): self.publish(.failed(reason),ticket);return
            case .cancelled: return
            }
            switch self.ops.stop(session.generation) {
            case .success: break
            case .failure(let reason): self.publish(.failed(reason),ticket);return
            case .cancelled: return
            }
            stopped = true
            self.publish(.stopped,ticket)
        }
    }

    /// Boot and restore use the same serialized owner.
    func perform(_ action: @escaping @Sendable () -> Void) { queue.async(execute:action) }
    func progress() -> ResumeProgress? {
        lock.lock(); let job = work; lock.unlock()
        return job?.progress()
    }
    func drain() { queue.sync {} } // deterministic tests; never called on the UI thread
}

/// Main-actor assertion bookkeeping kept independent of UIKit for race tests.
struct ResumeLease {
    private(set) var expired=false
    private(set) var finished=false
    private var ticket:ResumeTicket?
    init(granted:Bool,required:Bool) { expired = required && !granted }
    mutating func bind(_ value:ResumeTicket?) -> ResumeTicket? {
        ticket=value;return expired ? value : nil
    }
    mutating func expire() -> ResumeTicket? {
        guard !finished else { return nil }
        expired=true;return ticket
    }
    mutating func finish() -> Bool {
        guard !finished else { return false };finished=true;return true
    }
}
