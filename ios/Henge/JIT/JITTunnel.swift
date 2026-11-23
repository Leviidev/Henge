// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
@preconcurrency import NetworkExtension

/// Henge's own loopback VPN (PlugIns/HengeTunnel.appex), present in builds made with `project.tunnel.yml`.
/// When it is, Built-in StikJIT needs no LocalDevVPN: Henge connects this tunnel right before its helper
/// reaches the device at 10.7.0.1, and disconnects it once JIT is on. The first connect asks the user to
/// allow Henge's VPN configuration. Log category "jit-tunnel".
@MainActor
enum HengeTunnel {
    static let extensionFile = "HengeTunnel.appex"
    private static let description = "Henge JIT"

    /// The extension's bundle identifier in this installation; nil when Henge was built without it.
    static var providerIdentifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(extensionFile) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    static var isEmbedded: Bool { providerIdentifier != nil }

    /// Whether this launch connected the tunnel, so that it is Henge's to disconnect.
    private static var connectedByHenge = false

    private static func log(_ line: String) { HengeLog.log("jit-tunnel", line) }

    /// Connects the tunnel, saving its configuration first when there is none (iOS asks the user to allow it),
    /// and calls `completion` once it is up, or with what went wrong. Already up, LocalDevVPN's or Henge's:
    /// nothing to do.
    static func connect(completion: @escaping (String?) -> Void) {
        guard let identifier = providerIdentifier else {
            completion("Henge was built without its VPN.")
            return
        }
        if LocalDevVPN.isConnected {
            completion(nil)
            return
        }
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            Task { @MainActor in
                if let error {
                    log("could not load the VPN configuration: \(error.localizedDescription)")
                    completion("Henge could not read its VPN configuration: \(error.localizedDescription)")
                    return
                }
                let manager = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
                } ?? NETunnelProviderManager()
                save(manager, identifier: identifier) { failure in
                    if let failure {
                        completion(failure)
                    } else {
                        start(manager, completion: completion)
                    }
                }
            }
        }
    }

    /// Disconnects the tunnel if this launch connected it.
    static func disconnectIfOurs() {
        guard connectedByHenge, let identifier = providerIdentifier else { return }
        connectedByHenge = false
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            Task { @MainActor in
                guard let manager = managers?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
                }) else { return }
                log("disconnecting")
                manager.connection.stopVPNTunnel()
            }
        }
    }

    private static func save(_ manager: NETunnelProviderManager, identifier: String,
                             completion: @escaping (String?) -> Void) {
        let configured = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
        if configured && manager.isEnabled {
            completion(nil)
            return
        }
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = identifier
        proto.serverAddress = "10.7.0.1"
        manager.protocolConfiguration = proto
        manager.localizedDescription = description
        manager.isEnabled = true
        log(configured ? "enabling the VPN configuration" : "adding the VPN configuration")
        manager.saveToPreferences { error in
            Task { @MainActor in
                if let error {
                    log("could not save the VPN configuration: \(error.localizedDescription)")
                    completion("Henge's VPN was not allowed: \(error.localizedDescription) "
                               + "Allow it when asked, then try again.")
                    return
                }
                // A configuration just saved must be loaded again before it can start.
                manager.loadFromPreferences { error in
                    Task { @MainActor in
                        completion(error.map { "Henge could not load its VPN: \($0.localizedDescription)" })
                    }
                }
            }
        }
    }

    private static func start(_ manager: NETunnelProviderManager, completion: @escaping (String?) -> Void) {
        let connection = manager.connection
        if connection.status == .connected {
            completion(nil)
            return
        }
        do {
            try connection.startVPNTunnel()
        } catch {
            log("could not start: \(error.localizedDescription)")
            completion("Henge's VPN did not start: \(error.localizedDescription)")
            return
        }
        log("starting")
        var observer: NSObjectProtocol?
        var timeout: Timer?
        var done = false
        var connecting = false
        let finish: (String?) -> Void = { failure in
            guard !done else { return }
            done = true
            observer.map(NotificationCenter.default.removeObserver)
            timeout?.invalidate()
            if failure == nil { connectedByHenge = true }
            log(failure ?? "connected")
            completion(failure)
        }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: connection,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated {
                switch connection.status {
                case .connected: finish(nil)
                case .connecting, .reasserting: connecting = true
                // It can still read disconnected before it starts connecting.
                case .disconnected where connecting, .invalid:
                    finish("Henge's VPN disconnected while starting. Try again.")
                default: break
                }
            }
        }
        timeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
            MainActor.assumeIsolated { finish("Henge's VPN did not connect within 15 seconds. Try again.") }
        }
    }
}
