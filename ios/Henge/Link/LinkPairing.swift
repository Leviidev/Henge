import Foundation
import Network
import Security
import SwiftUI

/// Local discovery is only an address hint. TLS possession of the pairing key
/// remains the authority; no key, user name or screen data is advertised.
struct LinkDiscoveredPeer: Identifiable, Equatable {
    static let serviceType = "_henge-link._tcp"
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
    var title: String { "Henge iPad · " + String(name.suffix(6)) }
    static func validName(_ name: String) -> Bool {
        name.hasPrefix("Henge-") && UUID(uuidString: String(name.dropFirst(6))) != nil
    }
    init?(endpoint: NWEndpoint) {
        guard case let .service(name, type, domain, _) = endpoint,
              Self.validName(name), type == Self.serviceType, domain == "local." else { return nil }
        self.name = name; self.endpoint = endpoint
    }
}

@MainActor
final class LinkDiscovery: ObservableObject {
    @Published private(set) var peers: [LinkDiscoveredPeer] = []
    @Published private(set) var status = ""
    private var browser: NWBrowser?
    private var generation = UUID()
    func start(wired: Bool) {
        stop(); let g = UUID(); generation = g
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        if wired { parameters.requiredInterfaceType = .wiredEthernet }
        let browser = NWBrowser(for: .bonjour(type: LinkDiscoveredPeer.serviceType, domain: "local."), using: parameters)
        self.browser = browser; status = "Looking for an iPad on your local network…"
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap { LinkDiscoveredPeer(endpoint: $0.endpoint) }
            // The same service can be seen on more than one interface.
            let unique = Dictionary(peers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self, self.generation == g else { return }
                self.peers = Array(unique)
                self.status = unique.isEmpty ? "No iPad found yet. Start the display link on your iPad, or use manual connection." : "Select your iPad. Its address and port are discovered automatically."
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in guard let self, self.generation == g else { return }; self.status = "Discovery unavailable. Allow Local Network in Settings, or use manual connection." }
            }
        }
        browser.start(queue: DispatchQueue(label: "henge.link.discovery", qos: .utility))
    }
    func stop() { generation = UUID(); browser?.cancel(); browser = nil; peers = [] }
    deinit { browser?.cancel() }
}

struct LinkHostPairing: Codable {
    var name: String
    var key: String
    static func fresh() throws -> Self { Self(name: "Henge-" + UUID().uuidString, key: try LinkTransport.newKey()) }
}
struct LinkSavedPeer: Codable {
    let name: String
    let key: String
    let wired: Bool
}

/// Explicit opt-in only. Device-local, unlocked-only Keychain items; neither
/// iCloud synchronization, UserDefaults, Documents nor log/Bonjour storage.
struct LinkPairingStore {
    static let shared = LinkPairingStore()
    let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "com.henge.app") + ".link-pairing-v2") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func load<T: Decodable>(_ account: String, as: T.Type) throws -> T? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LinkError.invalid("Saved pairing is unavailable. Unlock this device or pair manually. (\(status))") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func save<T: Encodable>(_ account: String, value: T) throws {
        let q = query(account), data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LinkError.invalid("Could not save pairing securely. Manual pairing is still available. (\(status))") }
    }
    func forget(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LinkError.invalid("Could not remove saved pairing (\(status))") }
    }
    func host(remember: Bool) throws -> LinkHostPairing {
        if !remember { return try .fresh() }
        if let saved = try load("host", as: LinkHostPairing.self) {
            guard LinkDiscoveredPeer.validName(saved.name) else { throw LinkError.invalid("Invalid saved pairing; forget it and pair again") }
            _ = try LinkTransport.parameters(key: saved.key, wired: false)
            return saved
        }
        let fresh = try LinkHostPairing.fresh(); try save("host", value: fresh); return fresh
    }
}
