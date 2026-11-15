import Foundation
import SwiftUI
import UIKit
import Metal
import CoreVideo

@MainActor
final class LinkHostService: ObservableObject {
    static let shared = LinkHostService()
    private let shaderLibrary:MTLLibrary?
    init(library:MTLLibrary? = nil) { shaderLibrary=library }
    @Published private(set) var key = ""
    @Published private(set) var pairingName = ""
    @Published private(set) var port: UInt16?
    @Published private(set) var status = "Connect the Duo before starting this Mac."
    @Published private(set) var mode: LinkMode?
    @Published private(set) var active = false
    @Published private(set) var connected = false
    @Published private(set) var controlOnly = false
    @Published private(set) var mirrorActive=false
    var streamsVideo:Bool { active || mirrorActive }
    private var transport: LinkTransport?
    private var encoder: LinkEncoder?
    private var keys = Set<Int>(), buttons = Set<Int>()
    private var token = UUID()
    var canStart: Bool { connected && mode != nil && encoder != nil }
    func listen(wired: Bool, remember: Bool = false) {
        guard !active, !controlOnly else { return }
        stop(); let generation = UUID(); token = generation
        do {
            let pairing = try LinkPairingStore.shared.host(remember: remember)
            key = pairing.key; pairingName = pairing.name
            HengeLog.log("link", "local Bonjour discovery enabled; remembered-pairing=\(remember); key never advertised")
            let channel = LinkTransport(); transport = channel
            channel.onStatus = { [weak self] text, okay in
                Task { @MainActor in
                    guard let self, self.token == generation else { return }
                    self.status = text; self.connected = okay
                    HengeLog.log("link", text)
                    if !okay {
                        self.releaseInput()
                        if self.active || self.controlOnly { self.endPeer(); self.status = text+" · Waiting for reconnect" }
                    }
                }
            }
            channel.onPacket = { [weak self,weak channel] packet in
                guard let channel else { return }
                let connection=channel.connectionIdentity
                guard packet.kind == 1, packet.payload.count <= 65536,
                      let command = try? JSONDecoder().decode(LinkControl.self, from: packet.payload) else { return }
                Task { @MainActor in
                    guard let self,self.token==generation,channel.connectionIdentity==connection else { return };self.receive(command)
                }
            }
            channel.onListening = { [weak self] port in
                Task { @MainActor in guard let self, self.token == generation else { return }; self.port = port }
            }
            channel.listen(key: key, wired: wired, port: 0, serviceName: pairingName)
            status = "Starting secure listener…"
        } catch { status = error.localizedDescription }
    }
    private func receive(_ command: LinkControl) {
        guard (try? command.validate()) != nil else { return }
        if command.type == "helloInput" {
            guard encoder == nil, mode == nil, !active else { return }
            controlOnly = true
            transport?.sendControl(LinkControl(type:"readyInput",down:GamepadHub.shared.keyboardMapping,capabilities:["inputOnly","gamepad","viewerVisibility","primaryMirror"]))
            transport?.setInputOnly()
            status = "Secure wireless keyboard, touchpad and gamepad connected; video is off."
            HengeLog.log("link","controls-only peer authenticated; no encoder, decoder or second display")
            return
        }
        if command.type == "hello", let proposed = command.mode {
            guard !active, !controlOnly, encoder == nil else { status = "This session's display mode is already fixed. Stop the Mac before pairing again."; return }
            do {
                guard let transport else { return }
                if henge_vm_state() == 1 || henge_vm_state() == 4 {
                    guard matchesRunningMode(proposed) else {
                        status = "Reconnect using the saved second monitor’s size and refresh rate. A new monitor requires restarting the Mac."; return
                    }
                }
                let created = try LinkEncoder(mode: proposed, library:shaderLibrary, requestFrame:{henge_vm_link_connected(1)}, send: { [weak transport] data, done in
                    guard let transport else { done(false); return }; transport.sendVideo(data, completion: done)
                }, report: { [weak self] message in
                    HengeLog.log("link", message)
                    if message == "first independent port-1 Metal frame captured" {
                        Task { @MainActor in self?.status = "Streaming the second monitor." }
                    }
                })
                encoder = created; mode = proposed
                transport.onVideoAcknowledged = { [weak created] sequence in created?.acknowledge(sequence) }
                transport.sendControl(LinkControl(type: "ready", mode: proposed, capabilities: ["viewerVisibility","gamepad"]))
                status = "Duo ready: \(proposed.width) × \(proposed.height), \(proposed.hz) Hz. Start this Mac."
                if henge_vm_state() == 1 || henge_vm_state() == 4 {
                    installFrameHandler(created); active=true; resumeVideoIfNeeded()
                }
                HengeLog.log("link", "peer authenticated; native mode=\(proposed.width)x\(proposed.height) hz=\(proposed.hz); primary mode unchanged")
            } catch { status = error.localizedDescription; HengeLog.log("link", status); stopKeepingStatus() }
            return
        }
        if command.type == "mirror",let enabled=command.down,controlOnly {
            if enabled { startMirror(requestedHz:command.x ?? 60) } else { stopMirror();transport?.sendControl(LinkControl(type:"mirror",down:false)) }
            return
        }
        if command.type == "visibility", let visible = command.visible {
            encoder?.setVisible(visible)
            if !visible { releaseInput() }
            else if mirrorActive { henge_vm_mirror_refresh() }
            else if active { henge_vm_link_connected(1) } // request the latest frame even when the guest is idle
            return
        }
        if command.type == "bye" { stop(); return }
        if command.type == "release" { releaseInput(); return }
        guard (active || controlOnly), henge_vm_state() == 1 else { return }
        switch command.type {
        case "move": henge_vm_mouse_move(Int32(command.x ?? 0), Int32(command.y ?? 0))
        case "scroll": henge_vm_mouse_scroll(Int32(command.x ?? 0), Int32(command.y ?? 0))
        case "key":
            if let code = command.code, let down = command.down {
                if down { keys.insert(code) } else { keys.remove(code) }; henge_vm_input_key(1,UInt8(code), down ? 1 : 0)
            }
        case "button":
            if let code = command.code, let down = command.down {
                if down { buttons.insert(code) } else { buttons.remove(code) }; henge_vm_input_button(1,Int32(code), down ? 1 : 0)
            }
        case "release": releaseInput()
        case "gamepad": if let pad = command.gamepad { GamepadHub.shared.set(pad,remote:true) }
        case "padMode": GamepadHub.shared.keyboardMapping = command.down ?? false
        case "bye": stop()
        default: break
        }
    }
    private func startMirror(requestedHz:Int) {
        if mirrorActive,encoder?.mode.hz==requestedHz { henge_vm_mirror_refresh();return }
        stopMirror()
        guard encoder==nil,henge_vm_state()==1,let transport else { return }
        var display=HengeVmDisplayMode()
        guard henge_vm_display_mode(0,&display)==0 else {
            status="The main Mac display is not ready yet. Try Video again after startup."
            transport.sendControl(LinkControl(type:"mirror",code:1,down:false));return
        }
        let stream=LinkMode(width:Int(display.width),height:Int(display.height),widthMM:Int(display.width_mm),heightMM:Int(display.height_mm),hz:min(requestedHz,Int(display.hz)))
        do {
            let created=try LinkEncoder(mode:stream,mirrorsPrimary:true,library:shaderLibrary,requestFrame:{henge_vm_mirror_refresh()},send:{ [weak transport] data,done in
                guard let transport else { done(false);return };transport.sendVideo(data,completion:done)
            },report:{ HengeLog.log("link-mirror",$0) })
            encoder=created;mirrorActive=true
            transport.onVideoAcknowledged={ [weak created] in created?.acknowledge($0) }
            transport.sendControl(LinkControl(type:"readyMirror",mode:stream,down:GamepadHub.shared.keyboardMapping,capabilities:["primaryMirror","gamepad","viewerVisibility"]))
            hv_pvg_link_set_primary_frame_handler(Self.captureHandler(created))
            henge_vm_mirror_refresh();status="Streaming the main Mac display with wireless controls."
        } catch { status=error.localizedDescription;stopMirror();transport.sendControl(LinkControl(type:"mirror",code:1,down:false)) }
    }
    private func stopMirror() {
        guard mirrorActive else { return }
        hv_pvg_link_set_primary_frame_handler(nil);mirrorActive=false
        encoder?.stop();encoder=nil;transport?.onVideoAcknowledged=nil
    }
    private static func captureHandler(_ encoder:LinkEncoder)->HvPvgLinkFrameHandler {
        { texture,queue,halfMode,cursor,x,y,w,h in
            guard let texture,let queue else { return }
            let t=Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue() as! MTLTexture
            let q=Unmanaged<AnyObject>.fromOpaque(queue).takeUnretainedValue() as! MTLCommandQueue
            let c=cursor.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture }
            encoder.capture(texture:t,queue:q,halfMode:halfMode,cursorTexture:c,rect:SIMD4(x,y,w,h))
        }
    }
    /// Called immediately before boot. No link means exactly the original port count.
    func prepareBoot() throws {
        if let mode {
            guard canStart, let encoder else { throw LinkError.invalid("The Duo disconnected. Cancel the display link or pair it again before booting.") }
            guard henge_vm_set_link_display(UInt32(mode.width), UInt32(mode.height), UInt32(mode.widthMM), UInt32(mode.heightMM), UInt32(mode.hz)) == 0 else { throw LinkError.invalid("Cannot configure the guest's second display") }
            installFrameHandler(encoder)
            active = true; status = "Waiting for macOS to activate guest display port 1…"
            HengeLog.log("link", "boot with two independent PVG ports; guest display activation requires device validation")
        } else {
            hv_pvg_link_set_frame_handler(nil)
            _ = henge_vm_set_link_display(0, 0, 0, 0, 0)
        }
    }
    private func installFrameHandler(_ encoder: LinkEncoder) {
            hv_pvg_link_set_frame_handler { texture, queue, halfMode, cursor, x, y, w, h in
                guard let texture, let queue else { return }
                let t = Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue() as! MTLTexture
                let q = Unmanaged<AnyObject>.fromOpaque(queue).takeUnretainedValue() as! MTLCommandQueue
                let c = cursor.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture }
                encoder.capture(texture: t, queue: q, halfMode: halfMode, cursorTexture: c, rect: SIMD4(x, y, w, h))
            }
    }
    private func matchesRunningMode(_ mode: LinkMode) -> Bool {
        var saved=HengeVmDisplayMode()
        return henge_vm_display_mode(1,&saved) == 0 && modeMatches(mode,saved)
    }
    private func modeMatches(_ mode: LinkMode,_ saved: HengeVmDisplayMode) -> Bool {
        saved.width == UInt32(mode.width) && saved.height == UInt32(mode.height) &&
            saved.width_mm == UInt32(mode.widthMM) && saved.height_mm == UInt32(mode.heightMM) && saved.hz == UInt32(mode.hz)
    }
    /// Snapshot ports remain disconnected until a matching authenticated peer returns.
    func resumeVideoIfNeeded() {
        if mirrorActive { henge_vm_mirror_refresh();return }
        guard active,let mode else { return }
        var saved=HengeVmDisplayMode()
        let result=henge_vm_display_mode(1,&saved)
        if result == -2 { return } // lifecycle notification will retry; no polling
        guard result == 0, modeMatches(mode,saved) else {
            stopKeepingStatus(); status="The saved monitor has a different mode. Reconnect with its original size and refresh rate."; return
        }
        if henge_vm_state() == 1 { henge_vm_link_connected(1) }
    }
    func forgetPairing() {
        guard !active, !controlOnly else { return }
        do { try LinkPairingStore.shared.forget("host"); stop(); status = "Saved key revoked. Create a new pairing before connecting again." }
        catch { status = error.localizedDescription }
    }
    func stop() { stopKeepingStatus(); status = "Display link stopped." }
    func trimMemory() { encoder?.trimMemory() }
    private func endPeer() {
        releaseInput();stopMirror()
        hv_pvg_link_set_frame_handler(nil)
        if active { henge_vm_link_connected(0) }
        active=false;connected=false;controlOnly=false
        encoder?.stop();encoder=nil;mode=nil;transport?.onVideoAcknowledged=nil
    }
    private func stopKeepingStatus() {
        token = UUID(); releaseInput();stopMirror()
        hv_pvg_link_set_frame_handler(nil)
        if active { henge_vm_link_connected(0) }
        active = false; connected = false; controlOnly = false
        encoder?.stop(); encoder = nil; transport?.stop(); transport = nil
        key = ""; pairingName = ""; port = nil; mode = nil
    }
    private func releaseInput() {
        henge_vm_input_release(1)
        GamepadHub.shared.set(.off,remote:true)
        keys.removeAll(); buttons.removeAll()
    }
}

@MainActor
final class LinkViewerService: ObservableObject {
    @Published private(set) var status = "Select a local iPad or enter its address manually."
    @Published private(set) var ready = false
    @Published private(set) var videoHz=60
    @Published private(set) var videoActive=false
    @Published private(set) var mirrorSupported=false
    @Published var keyboardMapping = false {
        didSet { if oldValue != keyboardMapping { send(LinkControl(type:"padMode",down:keyboardMapping)) } }
    }
    private struct Request {
        let host:String,port:UInt16,key:String,wired:Bool,mode:LinkMode
        let peer:LinkDiscoveredPeer?
        let remember:Bool,inputOnly:Bool
    }
    private var request:Request?
    private var transport = LinkTransport()
    private let decodeWorker = LinkDecodeWorker(report: { HengeLog.log("link-viewer", $0) })
    private var generation = UUID()
    private var decodeGeneration=UUID()
    private var hostReady: LinkControl?
    private var foreground=true
    private var wantsMirror=false
    private var mirrorHz=60
    private var retry=LinkReconnectPolicy()
    private var retryTask:Task<Void,Never>?
    var onPixel: ((CVPixelBuffer) -> Void)?
    func connect(host: String, port: UInt16, key: String, wired: Bool, mode: LinkMode, peer: LinkDiscoveredPeer? = nil, remember: Bool = false, inputOnly: Bool = false) {
        disconnect();foreground=true
        request=Request(host:host.trimmingCharacters(in:.whitespacesAndNewlines),port:port,key:key.trimmingCharacters(in:.whitespacesAndNewlines),wired:wired,mode:mode,peer:peer,remember:remember,inputOnly:inputOnly)
        attemptConnection()
    }
    private func clearConnection() {
        generation=UUID();ready=false;videoActive=false;mirrorSupported=false;hostReady=nil
        transport.onPacket=nil;transport.onStatus=nil;transport.onClosed=nil;transport.stop();transport=LinkTransport()
        decodeWorker.stop();decodeGeneration=UUID()
    }
    private func beginDecode(_ mode:LinkMode,generation g:UUID) {
        let mailbox=LinkPixelMailbox { [weak self] pixel in
            guard let self,self.generation==g,self.foreground else { return }
            self.onPixel?(pixel)
        }
        decodeGeneration=decodeWorker.start(mode:mode,output:{mailbox.submit($0)})
    }
    private func attemptConnection() {
        guard foreground,let request else { return }
        retryTask?.cancel();retryTask=nil;clearConnection()
        let g=generation,channel=transport
        if !request.inputOnly { videoHz=request.mode.hz;beginDecode(request.mode,generation:g) }
        channel.onStatus={ [weak self,weak channel] text,connected in
            Task { @MainActor in
                guard let self,let channel,self.generation==g else { return }
                self.status=text
                if connected {
                    channel.sendControl(LinkControl(type:request.inputOnly ? "helloInput" : "hello",mode:request.inputOnly ? nil : request.mode))
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds:8_000_000_000)
                        guard !Task.isCancelled,let self,self.generation==g,!self.ready else { return }
                        self.connectionLost("Host did not accept the requested mode. Update Henge on both devices.",generation:g)
                    }
                }
            }
        }
        channel.onClosed={ [weak self] reason in
            Task { @MainActor in self?.connectionLost(reason,generation:g) }
        }
        channel.onPacket={ [weak self,weak channel] packet in
            // Mutating service state and choosing decode generations is confined
            // to MainActor. Decode and acknowledgements remain off-main.
            Task { @MainActor in
                guard let self,self.generation==g else { return }
                if packet.kind==1,let command=try? JSONDecoder().decode(LinkControl.self,from:packet.payload),(try? command.validate()) != nil {
                    if command.type==(request.inputOnly ? "readyInput" : "ready"),command.mode==(request.inputOnly ? nil : request.mode),
                       !request.inputOnly || command.capabilities?.contains("inputOnly")==true {
                        self.hostReady=command;self.ready=true;self.retry.reset()
                        self.mirrorSupported=request.inputOnly && command.capabilities?.contains("primaryMirror")==true
                        self.status=request.inputOnly ? "Connected. Wireless controls ready." : "Connected. Waiting for the second desktop."
                        if request.inputOnly { self.keyboardMapping=command.down ?? false;channel?.setInputOnly() }
                        if request.remember,let peer=request.peer {
                            do { try LinkPairingStore.shared.save("viewer",value:LinkSavedPeer(name:peer.name,key:request.key,wired:request.wired)) }
                            catch { self.status="Connected. "+error.localizedDescription }
                        }
                        if self.wantsMirror && self.mirrorSupported { channel?.sendControl(LinkControl(type:"mirror",x:self.mirrorHz,down:true)) }
                    } else if command.type=="readyMirror",request.inputOnly,self.wantsMirror,self.mirrorSupported,let mode=command.mode {
                        self.beginDecode(mode,generation:g);self.videoHz=mode.hz;self.videoActive=true;self.status="Connected. Main Mac screen and controls."
                    } else if command.type=="mirror",command.down==false,request.inputOnly {
                        self.videoActive=false;self.decodeWorker.stop();self.decodeGeneration=UUID()
                        if command.code==1 { self.status="Host video is not ready. Retry after the Mac display appears." }
                    }
                } else if packet.kind==2 && (!request.inputOnly || self.videoActive) {
                    self.decodeWorker.consume(packet.payload,generation:self.decodeGeneration,consumed:{ [weak channel] sequence in
                        channel?.sendControl(LinkControl(type:"videoAck",sequence:sequence))
                    },failed:{ [weak self] reason in
                        Task { @MainActor in self?.connectionLost(reason,generation:g) }
                    })
                }
            }
        }
        if let peer=request.peer { channel.connect(peer:peer,key:request.key,wired:request.wired) }
        else { channel.connect(host:request.host,key:request.key,wired:request.wired,port:request.port) }
    }
    private func connectionLost(_ reason:String,generation g:UUID) {
        guard generation==g,request != nil else { return }
        clearConnection() // invalidates late status/frame/timeout callbacks
        guard foreground else { status="Connection paused while Henge is in the background.";return }
        guard let delay=retry.nextDelay() else { status=reason+" · Automatic retries paused. Tap Reconnect.";return }
        status="Reconnecting in \(String(format:"%.1f",delay))s · \(reason)"
        let pending=generation
        retryTask=Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000)) } catch { return }
            guard let self,self.generation==pending,self.foreground,self.request != nil else { return }
            self.attemptConnection()
        }
    }
    func reconnect() { retry.reset();attemptConnection() }
    func setForeground(_ active:Bool) {
        guard foreground != active else { return }
        if !active { send(LinkControl(type:"release"));send(LinkControl(type:"visibility",visible:false)) }
        foreground=active
        if active { if !ready { retry.reset();attemptConnection() } else { send(LinkControl(type:"visibility",visible:true)) } }
        else { retryTask?.cancel();retryTask=nil;clearConnection();status="Connection paused; returning reconnects automatically." }
    }
    func setMirror(_ enabled:Bool,hz:Int = 60) {
        wantsMirror=enabled;mirrorHz=[30,60,120].contains(hz) ? hz : 60
        guard ready,mirrorSupported else { return }
        if !enabled { videoActive=false;decodeWorker.stop();decodeGeneration=UUID() }
        send(LinkControl(type:"mirror",x:mirrorHz,down:enabled))
    }
    func send(_ control: LinkControl) {
        guard ready else { return }
        if control.type == "visibility", hostReady?.supportsViewerVisibility != true { return }
        if ["gamepad","padMode"].contains(control.type), hostReady?.capabilities?.contains("gamepad") != true { return }
        if control.type=="mirror",!mirrorSupported { return }
        transport.sendControl(control)
    }
    func disconnect() {
        retryTask?.cancel();retryTask=nil;request=nil;wantsMirror=false;retry.reset();clearConnection()
    }
}
