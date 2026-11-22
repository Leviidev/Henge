// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Pairing on an Apple Vision Pro, for Built-in StikJIT.
///
/// visionOS pairs the other way round from iOS 27's on-device pairing (OnDevicePairing): there is no list of
/// computers to pair with. Settings › General › Remote Devices instead makes the headset advertise
/// `_remotepairing-manual-pairing._tcp`; a computer connects, the headset shows a code, and the computer sends it
/// back. Henge plays that computer for its own headset:
///
/// 1. connects its VPN (HengeTunnel, or LocalDevVPN), which the headset's services need to take Henge for a
///    computer on the network,
/// 2. finds this headset's pairing service (RSDPortResolver, OwnAddresses) once Remote Devices is open,
/// 3. connects to it at 10.7.0.1 (libhenge_rpclient, idevice's RemotePairingClient) and asks for the code the
///    headset shows, which the user types into Henge beside Settings.
///
/// Built only into builds with the VPN (project.tunnel.yml, HENGE_VISION_PAIRING). Log category
/// "jit-pairing": states only, never the code.
@MainActor final class VisionPairing: ObservableObject {
    static let shared = VisionPairing()

    /// How long to wait for Remote Devices to be opened.
    static let searchTimeout: TimeInterval = 300

    enum Phase: Equatable {
        case idle
        case connectingVPN
        /// Waiting for Settings › General › Remote Devices.
        case searching
        /// Found; waiting for the headset to show a code.
        case connecting
        /// The headset shows a code; the user types it.
        case code
        case pairing
        case paired
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    static var isSupported: Bool {
#if HENGE_VISION_PAIRING
        return Device.isVision
#else
        return false
#endif
    }

    var active: Bool {
        switch phase {
        case .connectingVPN, .searching, .connecting, .code, .pairing: return true
        default: return false
        }
    }

    /// One pairing attempt: where the pairing thread waits for the code.
    private final class Attempt: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var code: String?
        var cancelled = false
    }

    private var attempt: Attempt?

    private init() {}

    private func log(_ line: String) { HengeLog.log("jit-pairing", line) }

    func start() {
        guard Self.isSupported, !active else { return }
        let attempt = Attempt()
        self.attempt = attempt
        phase = .connectingVPN
        log("vision: started")
        connectVPN { [weak self] failure in
            guard let self, self.attempt === attempt else { return }
            if let failure {
                fail(failure)
                return
            }
            phase = .searching
            search(attempt)
        }
    }

    /// The code the headset shows.
    func submit(code: String) {
        guard case .code = phase, let attempt else { return }
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        phase = .pairing
        attempt.lock.lock()
        attempt.code = digits
        attempt.lock.unlock()
        attempt.ready.signal()
    }

    func cancel() {
        guard let attempt else { return }
        attempt.lock.lock()
        attempt.cancelled = true
        attempt.lock.unlock()
        attempt.ready.signal()
        self.attempt = nil
        phase = .idle
        log("vision: cancelled")
        HengeTunnel.disconnectIfOurs()
    }

    func reset() {
        if active { cancel() }
        phase = .idle
    }

    private func fail(_ message: String) {
        attempt = nil
        phase = .failed(message)
        log("vision: failed")
        HengeTunnel.disconnectIfOurs()
    }

    private func connectVPN(_ completion: @escaping (String?) -> Void) {
        if LocalDevVPN.isConnected {
            completion(nil)
        } else if HengeTunnel.isEmbedded {
            HengeTunnel.connect(completion: completion)
        } else {
            completion("Connect LocalDevVPN, then try again.")
        }
    }

    /// Looks for this headset's pairing service until Remote Devices is opened, or the attempt ends.
    private func search(_ attempt: Attempt) {
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(Self.searchTimeout)
            var port: UInt16?
            while port == nil, Date() < deadline {
                attempt.lock.lock()
                let cancelled = attempt.cancelled
                attempt.lock.unlock()
                if cancelled { return }
                port = RSDPortResolver.resolve(serviceType: RSDPortResolver.manualPairingServiceType, timeout: 3).port
            }
            DispatchQueue.main.async {
                guard self.attempt === attempt else { return }
                guard let port else {
                    self.fail("Remote Devices wasn't opened within \(Int(Self.searchTimeout / 60)) minutes. Try again.")
                    return
                }
                self.log("vision: found the pairing service")
                self.phase = .connecting
                self.pair(attempt, port: port)
            }
        }
    }

    private func pair(_ attempt: Attempt, port: UInt16) {
#if HENGE_VISION_PAIRING
        let context = Unmanaged.passRetained(attempt)
        DispatchQueue.global(qos: .userInitiated).async {
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            var error: UnsafeMutablePointer<CChar>?
            let status = henge_rpclient_pair("10.7.0.1", port, OnDevicePairing.hostName, { raw in
                guard let raw else { return nil }
                let attempt = Unmanaged<Attempt>.fromOpaque(raw).takeUnretainedValue()
                DispatchQueue.main.async { VisionPairing.shared.askForCode(attempt) }
                attempt.ready.wait()
                attempt.lock.lock()
                defer { attempt.lock.unlock() }
                guard !attempt.cancelled, let code = attempt.code else { return nil }
                return strdup(code)
            }, context.toOpaque(), &bytes, &length, &error)
            context.release()
            let data = bytes.map { Data(bytes: $0, count: length) }
            if let bytes { henge_rpclient_bytes_free(bytes, length) }
            let message = error.map { String(cString: $0) }
            if let error { henge_rpclient_string_free(error) }
            DispatchQueue.main.async {
                VisionPairing.shared.finished(attempt, status: status, data: data, message: message)
            }
        }
#endif
    }

    private func askForCode(_ attempt: Attempt) {
        guard self.attempt === attempt else { return }
        log("vision: the headset shows a code")
        phase = .code
    }

    private func finished(_ attempt: Attempt, status: Int32, data: Data?, message: String?) {
        guard self.attempt === attempt else { return }
        self.attempt = nil
        switch status {
        case 0:
            do {
                guard let data else { throw NSError(domain: "HengeJIT", code: 20) }
                try JITCoordinator.shared.storeOnDevicePairing(data)
                phase = .paired
                log("vision: paired")
                HengeTunnel.disconnectIfOurs()
            } catch {
                fail("Pairing finished, but Henge could not save the pairing file.")
            }
        case 1:
            phase = .idle
        default:
            fail(message.map { "Pairing failed: \($0). Check the code and try again." } ?? "Pairing failed. Try again.")
        }
    }
}
