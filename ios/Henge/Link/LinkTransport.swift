import Foundation
import Network
import Security

/// One authenticated TLS 1.2 AEAD peer. A random 256-bit PSK is entered out of band.
/// All mutable connection state belongs to queue. Local Bonjour is an address hint only; no cloud or guest NAT.
final class LinkTransport {
    let queue = DispatchQueue(label: "henge.link.transport", qos: .userInitiated)
    private let callbackLock = NSLock()
    private var identity=UUID()
    var connectionIdentity:UUID { callbackLock.lock();defer { callbackLock.unlock() };return identity }
    private func invalidateIdentity() { callbackLock.lock();identity=UUID();callbackLock.unlock() }
    private var packetHandler: ((LinkPacket) -> Void)?
    private var closedHandler: ((String) -> Void)?
    var onClosed: ((String) -> Void)? {
        get { callbackLock.lock();defer { callbackLock.unlock() };return closedHandler }
        set { callbackLock.lock();closedHandler=newValue;callbackLock.unlock() }
    }
    private var statusHandler: ((String, Bool) -> Void)?
    private var listeningHandler: ((UInt16) -> Void)?
    private var acknowledgedHandler: ((UInt64) -> Void)?
    var onVideoAcknowledged: ((UInt64) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return acknowledgedHandler }
        set { callbackLock.lock(); acknowledgedHandler = newValue; callbackLock.unlock() }
    }
    var onPacket: ((LinkPacket) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return packetHandler }
        set { callbackLock.lock(); packetHandler = newValue; callbackLock.unlock() }
    }
    var onStatus: ((String, Bool) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return statusHandler }
        set { callbackLock.lock(); statusHandler = newValue; callbackLock.unlock() }
    }
    var onListening: ((UInt16) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return listeningHandler }
        set { callbackLock.lock(); listeningHandler = newValue; callbackLock.unlock() }
    }
    private var listener: NWListener?, connection: NWConnection?
    private var parser = LinkParser()
    private var generation: UInt64 = 0
    private var videosPending = 0
    private var controlsPending = 0
    private var ready = false
    private var watchdog: DispatchSourceTimer?
    private var lastReceive = ProcessInfo.processInfo.systemUptime
    private var receiveTimeout: TimeInterval = 12
    func setInputOnly() { queue.async { self.receiveTimeout = 4 } }
    private var controlWindow: TimeInterval = 0
    private var controlCount = 0
    static let port: UInt16 = 49173
    static func newKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LinkError.invalid("Cannot create pairing key") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func parameters(key: String, wired: Bool) throws -> NWParameters {
        guard key.count == 43, let bytes = Data(base64Encoded: key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32 else { throw LinkError.invalid("Pairing key must be 43 characters") }
        let tls = NWProtocolTLS.Options()
        // Network.framework's external-PSK path uses the explicit TLS 1.2
        // AEAD PSK suite. Do not fall back to certificates or an unauthenticated
        // plaintext connection if a peer cannot negotiate it.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A8)!)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let psk = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("HengeLink-v2".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if wired { parameters.requiredInterfaceType = .wiredEthernet }
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
    func listen(key: String, wired: Bool, port: UInt16 = 49173, serviceName: String? = nil) {
        queue.async { [self] in
            // Cancellation is asynchronous. Fence and fully close the old
            // listener before rebinding, especially after a rejected handshake.
            let previous = listener; listener = nil
            stopNow(); let g = generation
            var started = false
            let start = { [self] in
                guard generation == g, !started else { return }; started = true
                startListener(key: key, wired: wired, port: port, serviceName: serviceName)
            }
            if let previous {
                previous.newConnectionHandler = { $0.cancel() }
                previous.stateUpdateHandler = { state in if case .cancelled = state { start() } }
                previous.cancel()
                if case .cancelled = previous.state { start() }
            } else { start() }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.generation == g, !started else { return }
                self.fail("Previous listener is still closing; try pairing again")
            }
        }
    }
    private func startListener(key: String, wired: Bool, port: UInt16, serviceName: String?) {
        do {
            let l = try NWListener(using: Self.parameters(key: key, wired: wired), on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
            if let serviceName {
                guard LinkDiscoveredPeer.validName(serviceName) else { throw LinkError.invalid("Invalid local service name") }
                l.service = NWListener.Service(name: serviceName, type: LinkDiscoveredPeer.serviceType, domain: "local.")
            }
            listener = l
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, let l, self.listener === l else { return }
                if case .ready = state, let bound = l.port {
                    self.onListening?(bound.rawValue)
                    self.onStatus?("Listening on port \(bound.rawValue). Connect the Duo before starting macOS.", false)
                }
                if case .failed(let e) = state { self.fail("Listener: \(e.localizedDescription)") }
                if case .waiting(let e) = state { self.onStatus?("Listener waiting: \(e.localizedDescription)", false) }
            }
            l.newConnectionHandler = { [weak self, weak l] c in
                guard let self, let l, self.listener === l, self.connection == nil else { c.cancel(); return }
                self.attach(c, wired: wired)
            }
            l.start(queue: queue)
        } catch { fail(error.localizedDescription) }
    }
    func connect(host: String, key: String, wired: Bool, port: UInt16 = 49173) {
        queue.async { [self] in
            stopNow()
            do {
                guard let address = IPv4Address(host) else { throw LinkError.invalid("Enter a local IPv4 address, not a hostname or URL") }
                let ip = [UInt8](address.rawValue)
                guard ip[0] == 10 || ip[0] == 127 || (ip[0] == 172 && (16...31).contains(ip[1])) || (ip[0] == 192 && ip[1] == 168) || (ip[0] == 169 && ip[1] == 254) else { throw LinkError.invalid("Use a private or link-local IPv4 address on your own network") }
                let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: try Self.parameters(key: key, wired: wired))
                attach(c, wired: wired)
            } catch { fail(error.localizedDescription) }
        }
    }
    func connect(peer: LinkDiscoveredPeer, key: String, wired: Bool) {
        queue.async { [self] in
            stopNow()
            do {
                // Only locally scoped services of our exact type are accepted.
                guard LinkDiscoveredPeer(endpoint: peer.endpoint) != nil else { throw LinkError.invalid("Invalid local display service") }
                attach(NWConnection(to: peer.endpoint, using: try Self.parameters(key: key, wired: wired)), wired: wired)
            } catch { fail(error.localizedDescription) }
        }
    }
    private func attach(_ c: NWConnection, wired: Bool) {
        invalidateIdentity()
        connection = c; parser = LinkParser(); generation &+= 1; let g = generation
        onStatus?("Connecting securely…", false)
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.connection === c, self.generation == g else { return }
            switch state {
            case .ready:
                guard !wired || c.currentPath?.usesInterfaceType(.wiredEthernet) == true else { self.fail("A wired Ethernet path is required"); return }
                self.ready = true; self.lastReceive = ProcessInfo.processInfo.systemUptime
                self.onStatus?(wired ? "TLS connected over Ethernet" : "TLS connected over local network", true)
                self.receive(c, generation: g)
                self.watchdog?.cancel();self.watchdog=nil
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
                timer.setEventHandler { [weak self] in
                    guard let self, self.generation == g else { return }
                    if ProcessInfo.processInfo.systemUptime - self.lastReceive > self.receiveTimeout { self.fail("Link connection timed out; held input released"); return }
                    self.sendControl(LinkControl(type: "ping"))
                }
                self.watchdog = timer; timer.resume()
            case .failed(let e): self.fail(e.localizedDescription)
            case .cancelled: break
            case .waiting(let e): self.onStatus?("Waiting: \(e.localizedDescription)", false)
            default: break
            }
        }
        c.pathUpdateHandler = { [weak self, weak c] path in
            guard let self, let c, self.connection === c else { return }
            if wired && !path.usesInterfaceType(.wiredEthernet) { self.fail("Ethernet disconnected; Wi-Fi fallback is disabled") }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.generation == g, !self.ready else { return }; self.fail("Connection timed out")
        }
    }
    private func receive(_ c: NWConnection, generation g: UInt64) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, complete, error in
            guard let self, let c, self.connection === c, self.generation == g else { return }
            do {
                if let data {
                    for packet in try self.parser.append(data) {
                        self.lastReceive = ProcessInfo.processInfo.systemUptime
                        if packet.kind == 1 {
                            guard packet.payload.count <= 65536 else { throw LinkError.invalid("Oversize control message") }
                            let now = ProcessInfo.processInfo.systemUptime
                            if now - self.controlWindow >= 1 { self.controlWindow = now; self.controlCount = 0 }
                            self.controlCount += 1
                            guard self.controlCount <= 2400 else { throw LinkError.invalid("Control message rate exceeded") }
                            let control = try JSONDecoder().decode(LinkControl.self, from: packet.payload); try control.validate()
                            if control.type == "ping" { self.sendControl(LinkControl(type: "pong")); continue }
                            if control.type == "pong" { continue }
                            if control.type == "videoAck", let sequence = control.sequence {
                                self.onVideoAcknowledged?(sequence); continue
                            }
                        }
                        self.onPacket?(packet)
                    }
                }
                if complete || error != nil { self.fail(error?.localizedDescription ?? "Peer disconnected"); return }
                self.receive(c, generation: g)
            } catch { self.fail("Protocol: \(error.localizedDescription)") }
        }
    }
    func sendControl(_ control: LinkControl) {
        queue.async { [self] in
            do {
                try control.validate()
                guard controlsPending < 128 else { fail("Control queue overflow"); return }
                guard let c = connection, ready else { return }
                let data = try LinkPacket(kind: 1, payload: JSONEncoder().encode(control)).wire()
                controlsPending += 1; let g = generation
                c.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, self.generation == g else { return }; self.controlsPending -= 1
                    if let error { self.fail(error.localizedDescription) }
                })
            } catch { fail(error.localizedDescription) }
        }
    }
    /// No backlog: at most three video packets may wait in Network.framework. The
    /// producer also bounds GPU/encoder frames. Congestion is reported, not hidden.
    func sendVideo(_ data: Data, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard videosPending < 3, ready, let c = connection else { completion(false); return }
            do {
                let wire = try LinkPacket(kind: 2, payload: data).wire()
                videosPending += 1; let g = generation
                c.send(content: wire, completion: .contentProcessed { [weak self] error in
                    guard let self else { completion(false); return }
                    if self.generation == g { self.videosPending -= 1; if let error { self.fail(error.localizedDescription) } }
                    completion(error == nil && self.generation == g)
                })
            } catch { completion(false); fail(error.localizedDescription) }
        }
    }
    func stop() { queue.async { [self] in stopNow() } }
    private func fail(_ text: String) {
        // An authenticated host keeps its listener/key for a fresh peer socket.
        // Explicit stop still closes it; failed listeners must be recreated.
        var keep=listener != nil
        if let listener,case .failed = listener.state { keep=false }
        stopNow(keepingListener:keep);onStatus?(text,false);onClosed?(text)
    }
    deinit { watchdog?.cancel(); connection?.cancel(); listener?.cancel() }
    private func stopNow(keepingListener:Bool = false) {
        invalidateIdentity()
        generation &+= 1; ready = false; videosPending = 0; controlsPending = 0; receiveTimeout = 12
        watchdog?.cancel(); watchdog = nil
        connection?.stateUpdateHandler = nil; connection?.pathUpdateHandler = nil; connection?.cancel(); connection = nil
        if !keepingListener { listener?.cancel(); listener=nil };parser=LinkParser()
    }
}
