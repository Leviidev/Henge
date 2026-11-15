import Foundation
import Darwin
import Metal
import CoreVideo
import CoreMedia

func require(_ value: @autoclosure () -> Bool, _ text: String) {
    if !value() { fatalError(text) }
}
func mustReject(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Invalid peer data accepted") } catch {}
}
/// Models the production serial guest GPU worker: a paced retry samples the
/// current surface again, rather than retaining an old guest texture snapshot.
final class FixtureFrameSource {
    private let queue = DispatchQueue(label: "henge.test.guest-gpu")
    private var latest: (() -> Void)?
    func submit(_ frame: @escaping () -> Void) { queue.sync { latest = frame; frame() } }
    func refresh() { queue.async { [self] in latest?() } }
    func stop() { queue.sync { latest = nil } }
}
@main struct LinkChecks {
    static func main() {
        setbuf(stdout, nil)
        // Keep Apple's framework main run loop available. Blocking main on the
        // first Metal/Network initialization can prevent listener callbacks.
        DispatchQueue.global(qos: .userInitiated).async {
            do { try checks(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        dispatchMain()
    }
    static func checks() throws {
        var pacing=LinkCaptureBudget()
        pacing.accepted(now:10,hz:60)
        require(abs(pacing.delay(now:10)-1/60.0)<0.000001,"60Hz snapshot budget")
        pacing.accepted(now:20,hz:120)
        require(abs(pacing.delay(now:20)-1/120.0)<0.000001,"120Hz snapshot budget")
        require(pacing.delay(now:21)==0,"No backlogged deadline after an idle period")
        pacing.reset();require(pacing.delay(now:0)==0,"Visibility transition resets cadence")
        let firstIdentity=LinkFrameSequence.next(),secondIdentity=LinkFrameSequence.next()
        require(secondIdentity>firstIdentity,"Encoder replacement must not reuse outstanding ACK identities")
        var retry=LinkReconnectPolicy()
        let delays=(0..<12).compactMap { _ in retry.nextDelay() }
        require(delays.count==12 && delays[0]==0.35 && delays.allSatisfy { $0<=15 },"Reconnect backoff must be bounded")
        require(retry.nextDelay()==nil,"Retry budget must stop without polling")
        retry.reset();require(retry.nextDelay()==0.35,"User retry resets backoff")
        try LinkControl(type:"mirror",down:true).validate()
        mustReject { try LinkControl(type:"mirror").validate() }
        try LinkControl(type:"helloInput").validate()
        try LinkControl(type:"readyInput",capabilities:["inputOnly","gamepad"]).validate()
        mustReject { try LinkControl(type:"gamepad",gamepad:GamepadState(hat:9)).validate() }
        mustReject { try LinkControl(type:"gamepad",gamepad:GamepadState(lx:Int16.min)).validate() }
        let local = GamepadState(buttons:1,lx:12000), remote = GamepadState(buttons:2,ry:-20000)
        let merged = GamepadState.merged(local,remote)
        require(merged.buttons==3 && merged.lx==12000 && merged.ry == -20000,"Input owners must merge without releasing each other")
        require(GamepadState.merged(.off,remote)==remote,"Disconnect preserves other owner")
        require(GamepadState(buttons:1,lx:-9000,ly:-9000).mappedKeys==Set<UInt8>([4,26,44]),"Keyboard fallback is WASD and jump")
        let pad = LinkControl(type:"gamepad",gamepad:merged)
        let decodedPad = try JSONDecoder().decode(LinkControl.self,from:JSONEncoder().encode(pad))
        require(decodedPad.gamepad==merged,"Full gamepad state wire roundtrip")
        print("PASS controls-only protocol, strict gamepad bounds, multi-owner state, keyboard mapping and release")
        let mode = LinkMode(width: 320, height: 240, widthMM: 70, heightMM: 52, hz: 60)
        try mode.validate()
        let legacyReady = try JSONDecoder().decode(LinkControl.self, from: JSONEncoder().encode(LinkControl(type: "ready", mode: mode)))
        require(!legacyReady.supportsViewerVisibility, "Legacy protocol-2 host must not receive optional visibility messages")
        let negotiated = try JSONDecoder().decode(LinkControl.self, from: JSONEncoder().encode(LinkControl(type: "ready", mode: mode, capabilities: ["viewerVisibility"])))
        require(negotiated.supportsViewerVisibility, "New host must advertise visibility support")
        struct LegacyReady: Decodable { let version:Int; let type:String; let mode:LinkMode }
        let oldViewer = try JSONDecoder().decode(LegacyReady.self, from: JSONEncoder().encode(negotiated))
        require(oldViewer.version == 2 && oldViewer.mode == mode, "Optional ready capabilities must preserve older viewers")
        mustReject { try LinkControl(type: "ready", mode: mode, capabilities: Array(repeating:"x",count:9)).validate() }
        mustReject { try LinkControl(type: "visibility").validate() }
        try LinkControl(type: "visibility", visible:false).validate()
        try LinkControl(type: "release").validate()
        try LinkControl(type: "videoAck", sequence: 1).validate()
        mustReject { try LinkControl(type: "videoAck", sequence: 0).validate() }
        mustReject { try LinkControl(version: 1, type: "release").validate() }
        linkFlowChecks(mode)
        let pairingDone = DispatchSemaphore(value: 0)
        Task { @MainActor in
            do { try await linkPairingChecks(); pairingDone.signal() }
            catch { fatalError("Pairing checks: \(error)") }
        }
        require(pairingDone.wait(timeout: .now() + 30) == .success, "Pairing checks stalled")
        try LinkControl(type: "move", x: 4096, y: -4096).validate()
        mustReject { try LinkControl(type: "move", x: Int.min, y: 0).validate() }
        mustReject { try LinkControl(type: "key", code: 232, down: true).validate() }
        mustReject { try LinkMode(width: Int.max, height: 240, widthMM: 1, heightMM: 1, hz: 60).validate() }
        let payload = try JSONEncoder().encode(LinkControl(type: "hello", mode: mode))
        let wire = try LinkPacket(kind: 1, payload: payload).wire()
        for split in 0...wire.count {
            var parser = LinkParser()
            let one = try parser.append(Data(wire.prefix(split))), two = try parser.append(Data(wire.dropFirst(split)))
            require(one.count + two.count == 1, "Fragmentation lost a control packet")
            require((one + two)[0].payload == payload, "Payload changed")
        }
        var parser = LinkParser(), received = 0
        for byte in wire + wire { received += try parser.append(Data([byte])).count }
        require(received == 2, "Coalesced packets lost")
        for invalid in [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 1, 9])] {
            mustReject { var p = LinkParser(); _ = try p.append(invalid) }
        }
        var video = LinkVideoHeader(codec: "hevc", width: 320, height: 240, sequence: 1, parameterSets: [Data([1]), Data([2]), Data([3])])
        let packed = try video.pack(Data([0, 0, 0, 1, 7]))
        let (unpacked, coded) = try LinkVideoHeader.unpack(packed)
        require(unpacked.sequence == 1 && coded == Data([0, 0, 0, 1, 7]), "Video framing changed")
        var padded = LinkVideoHeader(codec: "hevc", width: 2853, height: 2007, sequence: 1, parameterSets: [Data([1]), Data([2]), Data([3])], codedWidth: 2854, codedHeight: 2008)
        _ = try LinkVideoHeader.unpack(padded.pack(Data([1])))
        padded.codedWidth = 2852; mustReject { _ = try LinkVideoHeader.unpack(padded.pack(Data([1]))) }
        padded.codedWidth = 2860; mustReject { _ = try LinkVideoHeader.unpack(padded.pack(Data([1]))) }
        video.width = 0; mustReject { _ = try LinkVideoHeader.unpack(video.pack(Data([1]))) }
        print("PASS protocol: fragmentation, coalescing, hostile bounds, mode/input validation, video framing")
        try tls(mode)
        if ProcessInfo.processInfo.environment["HENGE_CI_EMULATED_RUNNER"] == "1" {
            print("NOT REVALIDATED hardware VideoToolbox codec/pixel checks: this runner is a Mac emulated by Henge, not a physical Mac with an AVE encoder. Prior physical-Mac Link run: 42597605953. UI typecheck/protocol/credits/worker/Keychain/TLS/discovery still run.")
        } else {
            try hardware(mode)
            try hardware(LinkMode(width: 1920, height: 1350, widthMM: 160, heightMM: 113, hz: 120))
            try hardware(LinkMode(width: 2853, height: 2007, widthMM: 157, heightMM: 110, hz: 120))
        }
    }
    static func tls(_ mode: LinkMode) throws {
        let key = try LinkTransport.newKey(), server = LinkTransport(), client = LinkTransport()
        require(key.count == 43, "Key encoding")
        mustReject { _ = try LinkTransport.parameters(key: "short", wired: true) }
        let listening = DispatchSemaphore(value: 0), connected = DispatchSemaphore(value: 0), hello = DispatchSemaphore(value: 0), response = DispatchSemaphore(value: 0)
        var serverPort: UInt16 = 0
        server.onListening = { serverPort = $0; listening.signal() }
        server.onStatus = { text, _ in print("server: \(text)") }
        client.onStatus = { text, ready in print("client: \(text)"); if ready { connected.signal() } }
        server.onPacket = { packet in
            if let control = try? JSONDecoder().decode(LinkControl.self, from: packet.payload), control.type == "hello", control.mode == mode {
                hello.signal(); server.sendControl(LinkControl(type: "ready", mode: mode))
            }
        }
        client.onPacket = { packet in if let c = try? JSONDecoder().decode(LinkControl.self, from: packet.payload), c.type == "ready", c.mode == mode { response.signal() } }
        server.listen(key: key, wired: false, port: 0)
        require(listening.wait(timeout: .now() + 10) == .success, "TLS listener failed")
        client.connect(host: "127.0.0.1", key: key, wired: false, port: serverPort)
        require(connected.wait(timeout: .now() + 10) == .success, "TLS PSK handshake failed")
        client.sendControl(LinkControl(type: "hello", mode: mode))
        require(hello.wait(timeout: .now() + 5) == .success && response.wait(timeout: .now() + 5) == .success, "Encrypted negotiation failed")
        client.stop(); server.stop()
        server.queue.sync {}; client.queue.sync {}
        let rejected = DispatchSemaphore(value: 0), wrong = LinkTransport()
        let badServer = LinkTransport(), listening2 = DispatchSemaphore(value: 0)
        var rejectedPort: UInt16 = 0
        badServer.onListening = { rejectedPort = $0; listening2.signal() }
        badServer.onStatus = { text, _ in print("pairing-recovery: \(text)") }
        badServer.listen(key: key, wired: false, port: 0)
        require(listening2.wait(timeout: .now() + 5) == .success, "TLS second listener failed")
        wrong.onStatus = { text, ready in
            if ready { fatalError("Wrong pairing key authenticated") }
            if text != "Connecting securely…" { print("wrong-key: \(text)"); rejected.signal() }
        }
        badServer.onPacket = { _ in fatalError("Unauthenticated peer sent application data") }
        wrong.connect(host: "127.0.0.1", key: try LinkTransport.newKey(), wired: false, port: rejectedPort)
        require(rejected.wait(timeout: .now() + 5) == .success, "TLS rejection wait")
        wrong.stop()
        wrong.queue.sync {}
        let recovery = LinkTransport(), recovered = DispatchSemaphore(value: 0)
        badServer.listen(key: key, wired: false, port: 0)
        require(listening2.wait(timeout: .now() + 10) == .success, "Listener did not recover after wrong-key rejection")
        recovery.onStatus = { _, ready in if ready { recovered.signal() } }
        recovery.connect(host: "127.0.0.1", key: key, wired: false, port: rejectedPort)
        require(recovered.wait(timeout: .now() + 10) == .success, "Correct-key reconnect failed after rejection")
        recovery.stop(); badServer.stop()
        recovery.queue.sync {}; badServer.queue.sync {}
        print("PASS transport: real TLS 1.2 AEAD PSK loopback, bidirectional negotiation, mismatched key denied and fresh listener recovered")
    }
    static func hardware(_ mode: LinkMode) throws {
        guard CommandLine.arguments.count > 1, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Native GPU fixture needs its metallib path") }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let done = DispatchSemaphore(value: 0)
        var expected = 0
        let decoder = LinkDecoder(mode: mode) { pixel in
            require(CVPixelBufferGetWidth(pixel) == mode.codedWidth && CVPixelBufferGetHeight(pixel) == mode.codedHeight, "Decoded codec canvas changed")
            var displayed: CMVideoFormatDescription?
            require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &displayed) == noErr, "Output format missing")
            let aperture = CMVideoFormatDescriptionGetCleanAperture(displayed!, originIsAtTopLeft: true)
            require(aperture == CGRect(x: 0, y: 0, width: mode.width, height: mode.height), "Native clean aperture shifted or resized: \(aperture)")
            let size = CMVideoFormatDescriptionGetPresentationDimensions(displayed!, usePixelAspectRatio: true, useCleanAperture: true)
            require(size == CGSize(width: mode.width, height: mode.height), "Native presentation dimensions changed")
            CVPixelBufferLockBaseAddress(pixel, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            let p = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixel)
            let i = mode.height/2 * row + mode.width/2 * 4
            if expected < 2 {
                require(Int(p[i+2]) > 180 && Int(p[i]) < 60 && Int(p[i+1]) < 60, "Metal/codec colour orientation incorrect")
                if expected == 1 {
                    let c = 28 * row + 28 * 4
                    require(Int(p[c+1]) > 180 && Int(p[c+2]) < 60, "Independent cursor overlay lost or misplaced")
                }
            } else {
                require((112...144).contains(Int(p[i+2])) && (112...144).contains(Int(p[i+1])) && (112...144).contains(Int(p[i])), "Half-float encoded gray was transformed twice")
            }
            done.signal()
        }
        let decodeGate = DispatchSemaphore(value: 0), blocked = DispatchSemaphore(value: 0)
        let stateLock = NSLock(); var holdNext = false
        let worker = LinkDecodeWorker(decode: { data in
            stateLock.lock(); let hold = holdNext; holdNext = false; stateLock.unlock()
            if hold { blocked.signal(); require(decodeGate.wait(timeout: .now() + 15) == .success, "Slow decoder gate timed out") }
            // Deliberately slower than one 120-Hz frame. The sender must bound
            // the real production worker despite immediate local TCP sends.
            Thread.sleep(forTimeInterval: 0.025)
            return try decoder.decode(data)
        }, report: { print("worker-fixture: \($0)") })
        let generation = worker.start(mode: mode, output: { _ in })
        let ack = DispatchSemaphore(value: 0), encoded = DispatchSemaphore(value: 0)
        func waitFrame() {
            require(encoded.wait(timeout: .now() + 15) == .success, "Hardware encode timed out")
            require(done.wait(timeout: .now() + 15) == .success, "Hardware decode timed out")
            require(ack.wait(timeout: .now() + 15) == .success, "Decoder ACK timed out")
        }
        let sender = LinkTransport(), receiver = LinkTransport(), key = try LinkTransport.newKey()
        let listening = DispatchSemaphore(value: 0), secure = DispatchSemaphore(value: 0)
        var port: UInt16 = 0
        sender.onListening = { port = $0; listening.signal() }
        sender.onStatus = { text, _ in print("video-listener: \(text)") }
        receiver.onStatus = { text, ready in print("video-receiver: \(text)"); if ready { secure.signal() } }
        receiver.onPacket = { packet in
            guard packet.kind == 2 else { return }
            worker.consume(packet.payload, generation: generation, consumed: { sequence in
                receiver.sendControl(LinkControl(type: "videoAck", sequence: sequence))
            }, failed: { fatalError("Video TLS round trip: \($0)") })
        }
        sender.listen(key: key, wired: false, port: 0)
        require(listening.wait(timeout: .now() + 10) == .success, "Video TLS listener")
        receiver.connect(host: "127.0.0.1", key: key, wired: false, port: port)
        require(secure.wait(timeout: .now() + 5) == .success, "Video TLS handshake")
        let source = FixtureFrameSource()
        let encoder = try LinkEncoder(mode: mode, library: library, requestFrame: { source.refresh() }, send: { data, finish in
            sender.sendVideo(data, completion: finish); encoded.signal()
        }, report: { print("fixture: \($0)") })
        sender.onVideoAcknowledged = { [weak encoder] sequence in
            encoder?.acknowledge(sequence); ack.signal()
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: mode.width, height: mode.height, mipmapped: false)
        d.storageMode = .shared; d.usage = .shaderRead
        let texture = device.makeTexture(descriptor: d)!
        var pixels = [UInt8](repeating: 0, count: mode.width * mode.height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i+2] = 255; pixels[i+3] = 255 }
        texture.replace(region: MTLRegionMake2D(0, 0, mode.width, mode.height), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: mode.width * 4)
        encoder.setVisible(false)
        source.submit { encoder.capture(texture: texture, queue: queue, halfMode: 0, cursorTexture: nil, rect: .zero) }
        let hiddenFence = queue.makeCommandBuffer()!; hiddenFence.commit(); hiddenFence.waitUntilCompleted()
        require(done.wait(timeout: .now() + 0.2) == .timedOut, "Hidden viewer received an encoded frame")
        encoder.trimMemory()
        encoder.setVisible(true)
        source.submit { encoder.capture(texture: texture, queue: queue, halfMode: 0, cursorTexture: nil, rect: .zero) }
        waitFrame()
        expected = 1
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
        cd.storageMode = .shared; cd.usage = .shaderRead
        let cursor = device.makeTexture(descriptor: cd)!
        var glyph = [UInt8](repeating: 0, count: 32*32*4)
        for i in stride(from: 0, to: glyph.count, by: 4) { glyph[i+1] = 255; glyph[i+3] = 255 }
        cursor.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0, withBytes: &glyph, bytesPerRow: 32*4)
        source.submit { encoder.capture(texture: texture, queue: queue, halfMode: 0, cursorTexture: cursor, rect: SIMD4(16, 16, 32, 32)) }
        waitFrame()
        expected = 2
        let hd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: mode.width, height: mode.height, mipmapped: false)
        hd.storageMode = .shared; hd.usage = .shaderRead
        let half = device.makeTexture(descriptor: hd)!
        var gray = [Float16](repeating: 0.5, count: mode.width*mode.height*4)
        for i in stride(from: 3, to: gray.count, by: 4) { gray[i] = 1 }
        half.replace(region: MTLRegionMake2D(0, 0, mode.width, mode.height), mipmapLevel: 0, withBytes: &gray, bytesPerRow: mode.width*8)
        source.submit { encoder.capture(texture: half, queue: queue, halfMode: 0, cursorTexture: nil, rect: .zero) }
        waitFrame()
        // Exercise real pool/texture/codec reuse beyond the three in-flight slots.
        for _ in 0..<30 {
            source.submit { encoder.capture(texture: half, queue: queue, halfMode: 0, cursorTexture: nil, rect: .zero) }
            waitFrame()
        }
        // Fill all three end-to-end credits while the real decoder is blocked.
        // Encoding completion, not arbitrary delays, drives each new surface.
        stateLock.lock(); holdNext = true; stateLock.unlock()
        source.submit { encoder.capture(texture: half, queue: queue, halfMode: 0, cursorTexture: nil, rect: .zero) }
        require(blocked.wait(timeout: .now() + 15) == .success, "Slow production worker did not block")
        require(encoded.wait(timeout: .now() + 15) == .success, "First held encode missing")
        for _ in 0..<2 {
            source.submit { encoder.capture(texture: half, queue: queue, halfMode: 0, cursorTexture: nil, rect: .zero) }
            require(encoded.wait(timeout: .now() + 15) == .success, "Paced retry failed to fill credit window")
        }
        source.submit { encoder.capture(texture: half, queue: queue, halfMode: 0, cursorTexture: nil, rect: .zero) }
        require(encoded.wait(timeout: .now() + 0.2) == .timedOut, "Fourth frame compressed before decoder credit")
        decodeGate.signal()
        // Retirement requests a fresh final snapshot. It must not vanish when
        // the guest becomes idle immediately after the congested update.
        for _ in 0..<3 {
            require(done.wait(timeout: .now() + 15) == .success, "Held decode missing")
            require(ack.wait(timeout: .now() + 15) == .success, "Held ACK missing")
        }
        waitFrame()
        require(done.wait(timeout: .now() + 0.2) == .timedOut, "Idle refresh became a continuous stream")
        print("PASS repeated native GPU/encoder/TLS/production worker: 37 frames including cadence retry, blocked consumer and final deferred snapshot")
        source.stop(); worker.stop(); encoder.stop(); sender.stop(); receiver.stop()
        sender.queue.sync {}; receiver.queue.sync {}
        print("PASS hardware: same-queue Metal snapshot → hardware encode → real TLS stream → hardware decode; native dimensions \(mode.width)x\(mode.height), red, cursor and half-float gray")
    }
}
