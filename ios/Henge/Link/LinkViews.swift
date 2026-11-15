import SwiftUI
import UIKit
import AVFoundation

struct LinkHostView: View {
    @ObservedObject private var link = LinkHostService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var wired = false
    @AppStorage("linkRememberPairing") private var remember = false
    let start: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Henge Link · experimental") {
                    Text("The Mac runs on this iPad. The Duo receives its extended display and sends input; it does not run a second Mac. Pair before starting this Mac.")
                    Toggle("Wired Ethernet only", isOn: $wired).disabled(link.connected || link.active)
                    Text("Wired mode needs compatible USB-C Ethernet adapters and a cable or switch. A plain USB-C cable is not supported.").font(.footnote)
                }
                Section("Pair the Duo") {
                    Toggle("Remember pairing on this iPad", isOn: $remember).disabled(link.connected || link.active)
                    Text("Remember on both devices to reuse the key. Saved keys stay in this device's Keychain; anyone with the key can view and control this Mac while its display link is listening.").font(.footnote)
                    Button(remember ? "Start saved display link" : "Create a pairing key") { link.listen(wired: wired, remember: remember) }.disabled(link.active)
                    if !link.pairingName.isEmpty { Text("Find on Duo: Henge iPad · " + String(link.pairingName.suffix(6))).font(.headline) }
                    Button("Forget saved pairing and revoke key", role: .destructive) { link.forgetPairing(); remember = false }.disabled(link.active)
                    if let port = link.port { Text("Connection port: \(port)").font(.headline).textSelection(.enabled) }
                    if !link.key.isEmpty {
                        Text(link.key).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        Button("Copy pairing key") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: link.key]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]) }
                        Text("On the Duo, select this iPad from Nearby iPads. Only the first pairing needs the key. IP and port are discovered automatically.").font(.footnote)
                        Text(wired ? "For manual connection on the Duo, choose Use this device as a display. Enter this iPad's local Ethernet IP, connection port and key. Find the IP in Settings → Ethernet → your adapter." : "Connect both devices to the same Wi-Fi network. On the Duo, turn off Wired Ethernet only and enter this iPad's Wi-Fi IP, connection port and key. Find the IP in Settings → Wi-Fi → your network → IP Address.").font(.footnote)
                    }
                    Text(link.status)
                    if let mode = link.mode { Text("Second monitor: \(mode.width) × \(mode.height) at \(mode.hz) Hz") }
                }
                Section("Main desktop on iPad") { LinkMainDesktopGuide() }
                Section {
                    Button("Start Mac with Duo display") { dismiss(); start() }.disabled(!link.canStart || link.active)
                    Button("Cancel display link", role: .destructive) { link.stop(); dismiss() }
                }
                Section { Text("The iPad keeps its selected resolution and refresh rate. The Duo receives hardware-compressed video at its native pixel size. Compression can affect fine text and colour; this is not a lossless DisplayPort connection. A second monitor also adds GPU and encoder work.").font(.footnote) }
            }
            .onChange(of: remember) { _, value in if !value { link.forgetPairing() } }
            .navigationTitle("Extend to Duo")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct LinkViewerView: View {
    @AppStorage("henge.link.controlsOnly") private var inputOnly = false
    @State private var inputTab = 0
    @AppStorage("henge.link.controllerVideo") private var controllerVideo=false
    @State private var fillVideo=false
    @AppStorage("henge.link.controllerVideoHz") private var controllerVideoHz=60
    @StateObject private var viewer = LinkViewerService()
    @ObservedObject private var gamepadPreferences = GamepadPreferences.shared
    @StateObject private var discovery = LinkDiscovery()
    @State private var selected: LinkDiscoveredPeer?
    @State private var saved: LinkSavedPeer?
    @State private var remember = false
    @State private var manual = false
    @State private var pairingNotice = ""
    @Environment(\.scenePhase) private var phase
    @State private var host = ""
    @State private var key = ""
    @State private var portText = ""
    @State private var wired = false
    @State private var connecting = false
    @State private var controlsHidden = false
    @State private var showGamepadSettings = false
    let exit: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if connecting {
                    if inputOnly && controllerVideo && viewer.mirrorSupported {
                        WirelessVideoControls(isDuo:HostScheduling.isDuo,tuning:gamepadPreferences.value,acceptsInput:viewer.ready,
                            sendPad:{viewer.send(LinkControl(type:"gamepad",gamepad:$0))},sendPointer:{viewer.send($0)},
                            video:LinkVideoSurface(viewer:viewer,toggleControls:toggleControls,fill:fillVideo,hz:viewer.videoHz),toolbar:controllerVideoToolbar)
                            .overlay { if !viewer.videoActive { VStack { Text(viewer.status);Button("Retry video") { viewer.setMirror(true,hz:controllerVideoHz) } }.padding().background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16)) } }
                    } else if inputOnly {
                        WirelessControlsPanel(status:viewer.status,tuning:gamepadPreferences.value,isDuo:HostScheduling.isDuo,acceptsInput:viewer.ready,supportsVideo:viewer.mirrorSupported,enableVideo:{controllerVideo=true;viewer.setMirror(true,hz:controllerVideoHz)},
                            mode:Binding(get:{ WirelessControlMode(rawValue:inputTab) ?? .touchpad },set:{inputTab=$0.rawValue}),
                            disconnect:{viewer.send(LinkControl(type:"release"));viewer.disconnect();connecting=false},
                            configure:{viewer.send(LinkControl(type:"release"));showGamepadSettings=true},
                            sendPad:{viewer.send(LinkControl(type:"gamepad",gamepad:$0))},sendPointer:{viewer.send($0)}) { mode in
                                LinkInputSurface(viewer:viewer,keyboard:mode == .keyboard)
                            }
                    } else {
                    LinkVideoSurface(viewer:viewer,toggleControls:toggleControls,hz:viewer.videoHz)
                        .ignoresSafeArea()
                        .accessibilityLabel("Extended Mac display")
                        .accessibilityHint("Three-finger tap hides or shows the display controls.")
                        .accessibilityAction(named: Text(controlsHidden ? "Show display controls" : "Hide display controls"), toggleControls)
                    if !controlsHidden {
                        HStack {
                            Button("Disconnect") { viewer.disconnect(); connecting = false }
                            Spacer()
                            Text(viewer.status).font(.caption).lineLimit(2)
                            Button { toggleControls() } label: { Image(systemName: "eye.slash") }
                                .accessibilityLabel("Hide display controls. Three-finger tap to show again.")
                        }.padding(8).background(.ultraThinMaterial)
                    }
                    }
                } else {
                    NavigationStack {
                        Form {
                            Section(inputOnly ? "Henge Link · wireless controls" : "Henge Link · display viewer") {
                                Text(inputOnly ? "Open Wireless Controls from the running Mac’s three-finger menu and create a key. This device sends keyboard, touchpad and gamepad input. Optional video mirrors the main Mac screen without adding a monitor. No Mac installation or JIT runs here." : "The Mac runs on your iPad. This device receives its second monitor and sends trackpad and hardware keyboard input. No Mac installation or JIT is required here.")
                                Text("Nearby iPads").font(.headline)
                                Text(discovery.status).font(.footnote)
                                ForEach(discovery.peers) { peer in
                                    Button {
                                        selected = peer; manual = false
                                        key = saved?.name == peer.name ? saved!.key : ""
                                    } label: {
                                        HStack { Text(peer.title); Spacer(); if selected?.id == peer.id { Image(systemName: "checkmark") } }
                                    }
                                }
                                Toggle("Use manual IP and port", isOn: $manual)
                                if manual {
                                    TextField("iPad local IP, for example 192.168.50.1", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                    TextField("Connection port shown on iPad", text: $portText).keyboardType(.numberPad)
                                }
                                SecureField("Pairing key from the iPad", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                                Toggle("Remember this iPad in Keychain", isOn: $remember).disabled(manual)
                                Text("Enable Remember pairing on the iPad too. After a successful first connection, choose this saved iPad and tap Connect next time. Only the key is retained securely; its current address and port are discovered again.").font(.footnote)
                                if saved != nil {
                                    Button("Forget saved iPad", role: .destructive) {
                                        do { try LinkPairingStore.shared.forget("viewer"); saved = nil; key = ""; remember = false; pairingNotice = "Saved pairing removed." }
                                        catch { pairingNotice = error.localizedDescription }
                                    }
                                }
                                if !pairingNotice.isEmpty { Text(pairingNotice).font(.footnote) }
                                Toggle("Wired Ethernet only", isOn: $wired)
                                Text(wired ? "Use compatible Ethernet adapters, not a plain USB-C cable. Both IP addresses must be on the same local subnet." : "Use the iPad's Wi-Fi IP address. Both devices must be on the same local network, with Wired Ethernet only turned off on both. A guest network may block device-to-device traffic.").font(.footnote)
                                Button(inputOnly ? "Connect wireless controls" : "Connect as second display") {
                                    let screen = UIScreen.main
                                    let scale = screen.nativeScale
                                    let w = Int((geometry.size.width * scale).rounded()), h = Int((geometry.size.height * scale).rounded())
                                    // Native phone density; the guest selects HiDPI using physical size.
                                    let mode = LinkMode(width: w, height: h, widthMM: max(1, Int(Double(w) / 460 * 25.4)), heightMM: max(1, Int(Double(h) / 460 * 25.4)), hz: min(120, screen.maximumFramesPerSecond))
                                    let peer = manual ? nil : selected
                                    let port = UInt16(portText) ?? 0
                                    guard peer != nil || (manual && !host.isEmpty && port > 0) else { return }
                                    discovery.stop(); controlsHidden = false
                                    viewer.connect(host: host, port: port, key: key, wired: wired, mode: mode, peer: peer, remember: remember && !manual,inputOnly:inputOnly); connecting = true
                                }.disabled(key.count != 43 || (manual ? (host.isEmpty || UInt16(portText) == nil || UInt16(portText) == 0) : selected == nil))
                                Text(viewer.status)
                            }
                            Section("Main desktop on iPad") { LinkMainDesktopGuide() }
                            Section { Text("Use landscape orientation before connecting. The negotiated pixel size stays fixed for this Mac session. Drag to move the pointer; tap to click; hold then drag to move windows; use two fingers to scroll. Move the pointer past the edge of the iPad desktop to reach this display. Tap with three fingers to hide or show the Disconnect/status bar.").font(.footnote) }
                            Button("Back to Henge") { viewer.disconnect(); exit() }
                        }.navigationTitle(inputOnly ? "Wireless Controls" : "Use as a display")
                    }
                }
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented:$showGamepadSettings) { GamepadSettings(mapping:$viewer.keyboardMapping) }
        .onAppear {
            do { saved = try LinkPairingStore.shared.load("viewer", as: LinkSavedPeer.self) }
            catch { pairingNotice = error.localizedDescription }
            if let saved { wired = saved.wired; remember = true }
            discovery.start(wired: wired)
        }
        .onChange(of: discovery.peers) { _, peers in
            if let selected, !peers.contains(where: { $0.id == selected.id }) { self.selected = nil }
            if !manual, selected == nil, let saved, let peer = peers.first(where: { $0.name == saved.name }) {
                selected = peer; key = saved.key; pairingNotice = "Saved iPad found. Tap Connect as second display."
            }
        }
        .onChange(of: remember) { _, value in
            if !value {
                do { try LinkPairingStore.shared.forget("viewer"); saved = nil }
                catch { pairingNotice = error.localizedDescription }
            }
        }
        .onChange(of: wired) { _, _ in if !connecting { selected = nil; discovery.start(wired: wired) } }
        .onChange(of: connecting) { _, value in
            if !value, phase == .active {
                saved = (try? LinkPairingStore.shared.load("viewer", as: LinkSavedPeer.self)) ?? saved
                discovery.start(wired: wired)
            }
        }
        .onChange(of: viewer.ready) { _, ready in
            if ready {
                viewer.send(LinkControl(type:"visibility",visible:phase == .active))
                if inputOnly { viewer.setMirror(controllerVideo,hz:controllerVideoHz) }
            }
            UIApplication.shared.isIdleTimerDisabled = ready
            // Reveal a real connection failure rather than leaving a hidden
            // error above a frozen last frame. It can still be hidden again.
            if !ready { controlsHidden = false }
        }
        .onChange(of: inputTab) { _, _ in viewer.send(LinkControl(type:"release")) }
        .statusBarHidden(connecting && controlsHidden)
        .onChange(of: phase) { _, phase in
            viewer.send(LinkControl(type: "visibility", visible: phase == .active))
            if phase == .background { viewer.setForeground(false);discovery.stop();UIApplication.shared.isIdleTimerDisabled=false }
            else if phase == .active { viewer.setForeground(true);if !connecting { discovery.start(wired:wired) } }
            else if phase == .inactive { viewer.send(LinkControl(type: "release")) }
        }
        .onDisappear { discovery.stop(); viewer.disconnect(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    private var controllerVideoToolbar:some View {
        HStack(spacing:8) {
            Button { controllerVideo=false;viewer.setMirror(false) } label: { Image(systemName:"video.slash").frame(width:36,height:36) }.accessibilityLabel("Video off")
            Spacer(minLength:0)
            Button { fillVideo.toggle() } label: { Image(systemName:fillVideo ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width:36,height:36) }.accessibilityLabel(fillVideo ? "Fit video" : "Fill video")
            Menu {
                Picker("Video refresh",selection:$controllerVideoHz) { Text("60 Hz").tag(60);Text("120 Hz · ProMotion").tag(120) }
            } label: { Text("\(controllerVideoHz)").monospacedDigit().frame(width:36,height:36) }.accessibilityLabel("Video refresh rate")
            Button { viewer.send(LinkControl(type:"release"));showGamepadSettings=true } label: { Image(systemName:"slider.horizontal.3").frame(width:36,height:36) }.accessibilityLabel("Controller sensitivity and layout settings")
            Button { viewer.reconnect() } label: { Image(systemName:"arrow.clockwise").frame(width:36,height:36) }.accessibilityLabel("Reconnect")
            Button { viewer.disconnect();connecting=false } label: { Image(systemName:"xmark.circle.fill").frame(width:36,height:36) }.accessibilityLabel("Disconnect wireless controls")
        }.font(.callout).padding(8).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:14))
        .opacity(controlsHidden ? 0 : 1).allowsHitTesting(!controlsHidden)
        .onChange(of:controllerVideoHz) { _,value in viewer.setMirror(true,hz:value) }
    }
    private func toggleControls() {
        controlsHidden.toggle()
        HengeLog.log("link-viewer", "viewer controls hidden=\(controlsHidden); native viewport and video mode unchanged")
    }
}

private struct LinkMainDesktopGuide: View {
    var body: some View {
        Text("If the Dock or main desktop appears on the Duo, open System Settings → Displays inside macOS, select the iPad display, then choose Use as → Main Display. macOS saves the main-display choice inside this Mac.")
        Text("Keep the Duo as an extended display. Move any existing windows back to the iPad by dragging their title bars across the shared screen edge. Changing the main display does not necessarily move windows that are already open. The Dock can also follow the pointer to another screen; move to the bottom of the iPad display to bring it back.")
        Text("All macOS processing stays on the iPad. No macOS install on the Duo, Mac reinstall, video-feed swap or resolution change is needed.")
    }
}

/// Native decoded buffers go straight to the system video layer. Its bounds do
/// not change the guest mode, and .resizeAspect preserves all source pixels.
private struct LinkVideoSurface: UIViewRepresentable {
    let viewer: LinkViewerService
    let toggleControls: () -> Void
    var fill=false
    var hz=60
    func makeUIView(context: Context) -> LinkVideoView {
        let view = LinkVideoView();view.maximumRate=hz;view.videoLayer.videoGravity=fill ? .resizeAspectFill : .resizeAspect
        view.rejectedPaste = { HengeLog.log("link-input","Paste rejected: use up to 16 ASCII characters at a time") }
        view.send = { [weak viewer] in viewer?.send($0) }
        view.toggleControls = toggleControls
        viewer.onPixel = { [weak view] pixel in view?.show(pixel) }
        viewer.send(LinkControl(type:"visibility",visible:true)) // latest idle frame after the view owns its sink
        return view
    }
    func updateUIView(_ view: LinkVideoView, context: Context) { view.toggleControls=toggleControls;view.maximumRate=hz;view.videoLayer.videoGravity=fill ? .resizeAspectFill : .resizeAspect }
    static func dismantleUIView(_ view: LinkVideoView, coordinator: ()) { view.send = nil; view.toggleControls = nil; view.clearVideo() }
}
private final class LinkVideoPulse:NSObject {
    weak var owner:LinkVideoView?
    @objc func tick(_ display:CADisplayLink) { owner?.presentLatest() }
}
private final class LinkVideoView: LinkInputView {
    var maximumRate=60
    private var latest:CVPixelBuffer?
    private var pulse:CADisplayLink?
    private var proxy:LinkVideoPulse?
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) { super.init(frame:frame); videoLayer.videoGravity = .resizeAspect; backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func show(_ pixel:CVPixelBuffer) {
        latest=pixel
        guard pulse==nil,window != nil else { return }
        let proxy=LinkVideoPulse();proxy.owner=self;self.proxy=proxy
        let pulse=CADisplayLink(target:proxy,selector:#selector(LinkVideoPulse.tick(_:)))
        let maximum=Float(min(min(window?.screen.maximumFramesPerSecond ?? 60,maximumRate),ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 120))
        pulse.preferredFrameRateRange=CAFrameRateRange(minimum:min(30,maximum),maximum:maximum,preferred:maximum)
        pulse.add(to:.main,forMode:.common);self.pulse=pulse
    }
    func clearVideo() { pulse?.invalidate();pulse=nil;proxy=nil;latest=nil;videoLayer.flushAndRemoveImage() }
    override func didMoveToWindow() { super.didMoveToWindow();if window==nil { clearVideo() } }
    fileprivate func presentLatest() {
        pulse?.invalidate();pulse=nil;proxy=nil
        guard let pixel=latest else { return };latest=nil
        var format: CMVideoFormatDescription?, sample: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first { first[kCMSampleAttachmentKey_DisplayImmediately] = true }
        if videoLayer.status == .failed { videoLayer.flush() }
        if videoLayer.isReadyForMoreMediaData { videoLayer.enqueue(sample) }
    }

}

private struct LinkInputSurface: View {
    let viewer: LinkViewerService
    let keyboard: Bool
    var body: some View {
        WirelessInputSurface(keyboard:keyboard,send:{[weak viewer] in viewer?.send($0)},rejectedPaste:{
            HengeLog.log("link-input","Paste rejected: use up to 16 ASCII characters at a time")
        })
    }
}

struct WirelessControlsHostView: View {
    @ObservedObject private var link = LinkHostService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var remember = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Another phone as your controls") {
                    Text("On the other phone, open Henge → Use as wireless keyboard or gamepad. Both devices must be on the same local network. Controls start with video off. The viewer can enable a live mirror of the main screen; it does not add a guest monitor.")
                    Toggle("Remember pairing in Keychain",isOn:$remember).disabled(link.connected)
                    Button("Create secure pairing key") { link.listen(wired:false,remember:remember) }.disabled(link.connected || link.active)
                    if !link.key.isEmpty {
                        Text(link.key).font(.system(.footnote,design:.monospaced)).textSelection(.enabled)
                        Button("Copy key") { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic:link.key]],options:[.localOnly:true,.expirationDate:Date().addingTimeInterval(300)]) }
                    }
                    if let port = link.port { Text("Manual port: \(port)") }
                    Text(link.status)
                    Button("Disconnect controls",role:.destructive) { link.stop() }.disabled(!link.controlOnly)
                }
                Section { Text("Anyone with the pairing key can control this Mac while listening. HID controller recognition depends on macOS and the game. Keyboard mapping provides WASD, Space, mouse look and trigger clicks as a separate fallback.").font(.footnote) }
            }.navigationTitle("Wireless Controls")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
