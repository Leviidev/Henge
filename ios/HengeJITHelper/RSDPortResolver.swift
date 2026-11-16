// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import dnssd

/// Finds the port this device's RemotePairing service listens on, for when Henge could not.
///
/// Since iOS 26 the device picks that port at boot and advertises it as `_remotepairing._tcp`; the fixed
/// 49152 StikJIT falls back to is closed then, so every attempt times out at 10.7.0.1:49152. Henge's own lookup
/// (RemotePairingPortDiscovery) connects to the service to learn its port, and on some devices that never
/// becomes ready. This reads the port from the service's SRV record with DNSServiceResolve instead, which
/// needs no connection.
///
/// Every device on the network advertises the same service type, so the first answer is not necessarily this
/// device's: a Mac, an iPhone and an iPad all show up. The SRV target's host name tells them apart, and the
/// caller still verifies the port before using it (HengeJITWork.findWorkingPort).
enum RSDPortResolver {
    struct Result {
        var port: UInt16?
        /// Every advertised port, this device's own first.
        var candidates: [UInt16]
        /// What happened, for the log: the port found, or why there is none.
        var detail: String
    }

    private static let serviceType = "_remotepairing._tcp"

    /// Blocks for at most `timeout`. Call it off the main thread.
    static func resolve(timeout: TimeInterval = 4) -> Result {
        let state = State()
        let queue = DispatchQueue(label: "com.henge.app.jit-helper.rsd-port")
        let context = Unmanaged.passRetained(state)
        defer { context.release() }

        var browseRef: DNSServiceRef?
        let browseError = DNSServiceBrowse(&browseRef, 0, 0, serviceType, "local.", browseCallback,
                                           context.toOpaque())
        guard browseError == kDNSServiceErr_NoError, let browseRef else {
            return Result(port: nil, candidates: [], detail: "browse could not start (\(describe(browseError)))")
        }
        state.queue = queue
        state.localHost = normalizeHost(localHostName)
        DNSServiceSetDispatchQueue(browseRef, queue)

        // Stop as soon as this device's own service is resolved; otherwise wait for the timeout and take
        // whatever was advertised.
        _ = state.done.wait(timeout: .now() + timeout)
        // Tear down on the queue the callbacks run on, so none runs after its ref is gone.
        return queue.sync {
            DNSServiceRefDeallocate(browseRef)
            state.resolveRefs.forEach(DNSServiceRefDeallocate)
            state.resolveRefs.removeAll()
            state.finished = true
            let ordered = state.ordered()
            let detail: String
            if let first = ordered.first {
                detail = "resolved \(serviceType) to port \(first.port) on \(first.host)"
                    + (ordered.count > 1 ? " (\(ordered.count) advertised)" : "")
            } else {
                var text = "no port within \(Int(timeout))s: \(state.seen) service(s) seen"
                if let error = state.lastError { text += ", last error \(describe(error))" }
                detail = text
            }
            return Result(port: ordered.first?.port, candidates: ordered.map(\.port), detail: detail)
        }
    }

    /// Only touched on `queue` once the browse has started.
    private final class State {
        let done = DispatchSemaphore(value: 0)
        var queue: DispatchQueue?
        var resolveRefs: [DNSServiceRef] = []
        var seen = 0
        var resolved: [(host: String, port: UInt16)] = []
        var localHost = ""
        var lastError: DNSServiceErrorType?
        var finished = false

        func add(host: String, port: UInt16) {
            guard !finished else { return }
            guard !resolved.contains(where: { $0.port == port && $0.host == host }) else { return }
            resolved.append((host, port))
            if normalizeHost(host) == localHost { done.signal() }
        }

        /// This device's own advertisement first, then the other devices' on the network.
        func ordered() -> [(host: String, port: UInt16)] {
            let own = resolved.filter { normalizeHost($0.host) == localHost }
            let rest = resolved.filter { normalizeHost($0.host) != localHost }
            return own + rest
        }
    }

    private static let browseCallback: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
        guard let context else { return }
        let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
        guard !state.finished else { return }
        guard error == kDNSServiceErr_NoError else {
            state.lastError = error
            return
        }
        guard (flags & kDNSServiceFlagsAdd) != 0, let name, let type, let domain else { return }
        state.seen += 1
        var resolveRef: DNSServiceRef?
        let resolveError = DNSServiceResolve(&resolveRef, 0, interface, name, type, domain, resolveCallback, context)
        guard resolveError == kDNSServiceErr_NoError, let resolveRef, let queue = state.queue else {
            state.lastError = resolveError
            return
        }
        state.resolveRefs.append(resolveRef)
        DNSServiceSetDispatchQueue(resolveRef, queue)
    }

    private static let resolveCallback: DNSServiceResolveReply = { _, _, _, error, _, host, port, _, _, context in
        guard let context else { return }
        let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError else {
            state.lastError = error
            return
        }
        // The port arrives in network byte order.
        let value = UInt16(bigEndian: port)
        guard value != 0 else { return }
        state.add(host: host.map { String(cString: $0) } ?? "?", port: value)
    }

    /// The Bonjour host name this device advertises, e.g. "iPad" for "iPad.local.".
    private static var localHostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        return ProcessInfo.processInfo.hostName
    }

    private static func describe(_ error: DNSServiceErrorType) -> String {
        switch Int(error) {
        case Int(kDNSServiceErr_PolicyDenied): return "PolicyDenied: Local Network access is off for Henge"
        case Int(kDNSServiceErr_NoAuth): return "NoAuth"
        case Int(kDNSServiceErr_ServiceNotRunning): return "ServiceNotRunning"
        default: return "DNSServiceErrorType \(error)"
        }
    }
}

/// "iPad.local." and "iPad" are the same host; mDNS names use hyphens for spaces.
private func normalizeHost(_ host: String) -> String {
    var name = host.lowercased()
    if name.hasSuffix(".") { name.removeLast() }
    if name.hasSuffix(".local") { name.removeLast(6) }
    return name.replacingOccurrences(of: " ", with: "-")
}
