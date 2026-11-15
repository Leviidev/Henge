import Foundation

struct ResumeBuildIdentity: Codable, Equatable, Sendable {
    let version: String
    let number: String
    let source: String
    let stamp: String
}

struct ResumeConfiguration: Codable, Equatable, Sendable {
    var schema = 1
    let build: ResumeBuildIdentity
    let macID: UUID
    let ecid: UInt64
    let seed: UInt64
    let ramMB: UInt64
    let cpus: Int
    let width: Int
    let height: Int
    let retina: Bool
    let hz: Int
    let mmWidth: Int
    let mmHeight: Int
    /// Host-only presentation, captured with the guest mode. Nil is legacy 1x.
    var presentationScale: Int? = nil

    private var validShape:Bool {
        schema == 1 && (1024...32768).contains(ramMB) && (1...8).contains(cpus) &&
        (1...8192).contains(width) && (1...8192).contains(height) && UInt64(width)*UInt64(height)<=33554432 &&
        (24...120).contains(hz) && (0...65535).contains(mmWidth) && (0...65535).contains(mmHeight) &&
        (mmWidth == 0) == (mmHeight == 0) &&
        (presentationScale == nil || presentationScale == 1 ||
         (presentationScale == 2 && !retina && width <= 4096 && height <= 4096))
    }

    func encoded() throws -> String {
        guard validShape else { throw ResumeIdentityError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = "HengeResume1:" + (try encoder.encode(self)).base64EncodedString()
        guard value.utf8.count < 1024 else { throw ResumeIdentityError.invalid }
        return value
    }

    static func decode(_ value: String, build: ResumeBuildIdentity, macID: UUID, ecid: UInt64, seed: UInt64,
                       ramMB: UInt64, cpus: Int) throws -> ResumeConfiguration {
        guard value.utf8.count < 1024, value.hasPrefix("HengeResume1:"),
              let data = Data(base64Encoded: String(value.dropFirst("HengeResume1:".count))),
              let config = try? JSONDecoder().decode(Self.self, from:data), config.validShape,
              config.ramMB == ramMB, config.cpus == cpus
        else { throw ResumeIdentityError.invalid }
        guard config.build == build else { throw ResumeIdentityError.otherBuild }
        guard config.macID == macID, config.ecid == ecid, config.seed == seed else { throw ResumeIdentityError.otherMac }
        return config
    }
}

enum ResumeIdentityError: LocalizedError {
    case invalid, otherBuild, otherMac
    var errorDescription: String? {
        switch self {
        case .invalid: return "The saved Mac is incomplete, damaged, or uses an older saved-state format. Its disk is kept."
        case .otherBuild: return "The saved Mac belongs to another Henge build. Its disk is kept; discard only the saved memory to start fresh."
        case .otherMac: return "The saved state belongs to another Mac or machine identity. Its disk is kept."
        }
    }
}

/// The native generation remains authoritative; this is only the immutable
/// configuration needed to reattach a view after an interrupted async start.
final class ResumeRuntimeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (ResumeConfiguration, UInt64)?
    private var viewRevision:UInt64=0
    private var viewActive=false
    func claimView()->UInt64 {
        lock.lock();defer {lock.unlock()};viewRevision &+= 1;viewActive=true;return viewRevision
    }
    func ownsView(_ revision:UInt64)->Bool {
        lock.lock();defer {lock.unlock()};return viewActive && viewRevision==revision
    }
    @discardableResult func releaseView(_ revision:UInt64)->Bool {
        lock.lock();defer {lock.unlock()}
        guard viewActive && viewRevision==revision else {return false};viewActive=false;return true
    }
    var hasActiveView:Bool {lock.lock();defer{lock.unlock()};return viewActive}

    func record(_ configuration:ResumeConfiguration,generation:UInt64) {
        lock.lock(); value=(configuration,generation); lock.unlock()
    }
    func configuration(macID:UUID,generation:UInt64,state:Int32)->ResumeConfiguration? {
        lock.lock(); defer { lock.unlock() }
        guard state == 1 || state == 4,let (configuration,stored)=value,
              stored == generation,configuration.macID == macID else { return nil }
        return configuration
    }
    func clear(generation:UInt64) {
        lock.lock(); if value?.1 == generation { value=nil }; lock.unlock()
    }
    func owns(macID:UUID,generation:UInt64)->Bool {
        lock.lock(); defer { lock.unlock() }
        return value?.0.macID == macID && value?.1 == generation
    }
}
