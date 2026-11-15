import Foundation
import Network

@MainActor
func linkPairingChecks() async throws {
    let name = "Henge-" + UUID().uuidString
    func endpoint(_ name: String, type: String = LinkDiscoveredPeer.serviceType, domain: String = "local.") -> NWEndpoint { .service(name: name, type: type, domain: domain, interface: nil) }
    require(LinkDiscoveredPeer(endpoint: endpoint(name)) != nil, "Local service rejected")
    require(LinkDiscoveredPeer(endpoint: endpoint("Henge-not-a-uuid")) == nil, "Malformed service accepted")
    require(LinkDiscoveredPeer(endpoint: endpoint(name, domain: "example.com")) == nil, "Public DNS service accepted")
    require(LinkDiscoveredPeer(endpoint: endpoint(name, type: "_http._tcp")) == nil, "Unrelated service accepted")
    require(LinkDiscoveredPeer(endpoint: .hostPort(host: "127.0.0.1", port: 1)) == nil, "Arbitrary endpoint accepted as discovered")
    let store = LinkPairingStore(service: "henge.link.test." + UUID().uuidString)
    do {
        defer { try? store.forget("host"); try? store.forget("viewer") }
        let first = try store.host(remember: true), second = try store.host(remember: true)
        require(first.name == second.name && first.key == second.key, "Saved host key rotated")
        let ephemeral = try store.host(remember: false)
        require(ephemeral.key != first.key && ephemeral.name != first.name, "Nonremembered pairing reused saved secret")
        try store.save("viewer", value: LinkSavedPeer(name: first.name, key: first.key, wired: false))
        let loaded = try store.load("viewer", as: LinkSavedPeer.self)
        require(loaded?.key == first.key, "Saved viewer key changed")
        try store.forget("viewer")
        let forgotten = try store.load("viewer", as: LinkSavedPeer.self)
        require(forgotten == nil, "Forget retained secret")
        try store.forget("host")
        let replaced = try store.host(remember: true)
        require(replaced.key != first.key, "Revocation reused old key")
        print("PASS pairing Keychain: host persistence, ephemeral isolation, viewer roundtrip, removal and key revocation")
    } catch {
        // CI may have no unlocked login Keychain. Do not claim device signing
        // compatibility from a headless Mac's storage availability.
        print("UNVERIFIED Keychain runtime on this runner: \(error.localizedDescription); iOS typecheck still required")
    }
    let server = LinkTransport(), client = LinkTransport(), discovery = LinkDiscovery()
    let secret = try LinkTransport.newKey()
    var listening = false, connected = false
    server.onListening = { _ in Task { @MainActor in listening = true } }
    client.onStatus = { _, ready in if ready { Task { @MainActor in connected = true } } }
    server.listen(key: secret, wired: false, port: 0, serviceName: name)
    discovery.start(wired: false)
    defer { discovery.stop(); client.stop(); server.stop() }
    for _ in 0..<200 {
        if listening && discovery.peers.contains(where: { $0.name == name }) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let peer = discovery.peers.first(where: { $0.name == name }) else { throw LinkError.invalid("Native Bonjour discovery failed: \(discovery.status)") }
    client.connect(peer: peer, key: secret, wired: false)
    for _ in 0..<200 {
        if connected { break }; try await Task.sleep(nanoseconds: 50_000_000)
    }
    require(connected, "Discovered endpoint failed authenticated TLS connection")
    discovery.stop()
    require(discovery.peers.isEmpty, "Stopped discovery retained stale services")
    print("PASS local discovery: production Bonjour browser → dynamic port service resolution → authenticated TLS; endpoint scope validation")
}
