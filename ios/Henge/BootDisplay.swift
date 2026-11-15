import SwiftUI
import QuartzCore
import CoreGraphics

/// The Mac's screen, refreshed a few times a second: what its GPU draws once
/// macOS is up. Before that, the boot framebuffer, which only ever holds the
/// progress bar (a virtual Mac's firmware draws no logo into it), so the logo
/// over it is the app's own.
struct BootDisplay: View {
    let display: DisplayRouter
    let role: DisplayTargetSelection.Role
    /// The id this view's layer connects to the router under.
    var surface = UUID()

    @State private var image: CGImage?
    @State private var gpuLive = false
    @State private var stopped = false
    @State private var wakeups = SessionWakeups()
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0

    var body: some View {
        ZStack {
            Color.black
            if !stopped {
                if !gpuLive {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        if image.height > image.width {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 44))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 44))
                            .foregroundStyle(.white)
                    }
                }
                GPUScreen(display: display, role: role, surface: surface,
                          matchScreenColors: matchScreenColors, brightness: screenBrightness)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SessionNativeEvents.changed)) { _ in wakeups.signal() }
        .task {
            SessionNativeEvents.start()
            var generation = henge_vm_generation()
            // Keep watching the lifecycle after the GPU takes over. Removing
            // GPUScreen clears its last frame on both device and external screens.
            while !Task.isCancelled {
                let next = henge_vm_generation(), state = henge_vm_state()
                if next != generation {
                    generation = next
                    gpuLive = false
                    image = nil
                }
                if state == 2 || state == 3 {
                    stopped = true
                    image = nil
                    gpuLive = false
                } else {
                    stopped = false
                    var observation=HengeVmObservation()
                    guard henge_vm_try_observation(&observation) != 0 else {
                        await wakeups.wait(seconds:0.1);continue
                    }
                    if !gpuLive && observation.counters.gpu_frames > 0 {
                        gpuLive = true
                        image = nil
                    }
                    if !gpuLive { image = Self.snapshot() ?? image }
                }
                // Only the firmware framebuffer needs polling. Once Metal is
                // live, native lifecycle events clear/recreate its target.
                await wakeups.wait(seconds: state == 1 && !gpuLive ? 0.1 : nil)
            }
        }
    }

    static func snapshot() -> CGImage? {
        var px: UnsafePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
        guard henge_vm_boot_display(&px, &w, &h, &stride) == 0, let px else { return nil }
        defer { henge_vm_free_display(px) }
        let bytes = Int(stride) * Int(h)
        let data = Data(bytes: px, count: bytes) // a copy: the guest keeps drawing
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(stride),
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A layer the engine draws the Mac's frames into, with the GPU, without the main thread.
private struct GPUScreen: UIViewRepresentable {
    let display: DisplayRouter
    let role: DisplayTargetSelection.Role
    let surface: UUID
    let matchScreenColors: Bool
    let brightness: Double
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)

    final class Screen: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }

        private let id: UUID
        private let display: DisplayRouter
        private let role: DisplayTargetSelection.Role
        private var attached = false
        private var lastSize: CGSize = .zero
        private var lastWindow: ObjectIdentifier?
        private var lastScale: CGFloat = 0

        init(display: DisplayRouter, role: DisplayTargetSelection.Role, surface: UUID) {
            self.id = surface
            self.display = display
            self.role = role
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            layer.contentsGravity = .resizeAspect
            layer.isOpaque = false
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attachIfReady() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfReady()
        }

        private func attachIfReady() {
            guard let window, bounds.width > 0, bounds.height > 0,
                  let metal = layer as? CAMetalLayer else { return }
            if !attached {
                attached = true
                lastSize = bounds.size
                lastWindow = ObjectIdentifier(window); lastScale = window.screen.scale
                metal.contentsScale = lastScale
                HengeLog.log("display", "display-viewport: role=\(role) window=\(window.bounds.width)x\(window.bounds.height) layer=\(bounds.width)x\(bounds.height) scale=\(window.screen.scale)")
                display.connect(id, layer: metal, role: role)
            } else if lastSize != bounds.size || lastWindow != ObjectIdentifier(window) || lastScale != window.screen.scale {
                lastSize = bounds.size
                lastWindow = ObjectIdentifier(window); lastScale = window.screen.scale
                metal.contentsScale = lastScale
                display.refresh(id)
            }
        }

        func detach() {
            guard attached else { return }
            attached = false
            display.disconnect(id)
        }
    }

    private func setColorSpace(_ view: Screen) {
        let metalLayer = view.layer as! CAMetalLayer
        // The guest's display profile is sRGB, and the presenter writes sRGB
        // values. A nil colorspace skips matching on wide-gamut iPad screens.
        let desired = matchScreenColors ? Self.srgb : nil
        if metalLayer.colorspace !== desired { metalLayer.colorspace = desired }
        let alpha = CGFloat(min(max(brightness, 0.4), 1))
        if view.alpha != alpha { view.alpha = alpha }
    }

    func makeUIView(context: Context) -> Screen {
        if ProcessInfo.processInfo.environment["HV_COLOR_PROBE"] != nil {
            // What the screen itself is, for the colour probe (the engine logs the layer and the frames).
            let s = UIScreen.main
            let gamut = s.traitCollection.displayGamut == .P3 ? "P3" : s.traitCollection.displayGamut == .SRGB ? "sRGB" : "unspecified"
            HengeLog.log("colorprobe", "colorprobe: v=1 src=swift event=screen gamut=\(gamut) scale=\(s.scale) nativeScale=\(s.nativeScale) "
                       + "bounds=\(Int(s.bounds.width))x\(Int(s.bounds.height)) maxEDR=\(s.potentialEDRHeadroom) currentEDR=\(s.currentEDRHeadroom) "
                       + "brightness=\(String(format: "%.2f", s.brightness)) refreshHz=\(s.maximumFramesPerSecond)")
        }
        let view = Screen(display: display, role: role, surface: surface)
        setColorSpace(view)
        return view
    }
    func updateUIView(_ view: Screen, context: Context) { setColorSpace(view) }
    static func dismantleUIView(_ view: Screen, coordinator: ()) { view.detach() }
}
