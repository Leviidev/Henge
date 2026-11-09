import SwiftUI

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(EngineTuning.refreshKey) private var refreshRate = 60
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(EngineTuning.wfiSpinKey) private var wfiSpin = false
    @AppStorage(EngineTuning.superblocksKey) private var superblocks = false
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB
    @AppStorage("henge.rosetta") private var intelApps = false

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT") {
                    LabeledContent("Status", value: jit.ready ? "On" : JITBootstrap.debuggedFlag ? "Code region not ready" : "Off")
                    Picker("Method", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge uses \(jit.method.title).")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Set up JIT") { jit.showSetup = true }
                    if !jit.ready {
                        Button(jit.busy ? "Preparing JIT…" : "Turn On JIT") { jit.enable() }
                            .disabled(jit.busy)
                        if let message = jit.error ?? JITBootstrap.lastFailure {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Turn on JIT when Henge opens", isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text("Henge connects LocalDevVPN first when it is off, and comes back.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Code region", value: jit.ready
                        ? "\(JITBootstrap.jitBytes >> 20) MB, ready"
                        : "Not allocated (\(JITBootstrap.jitBytes >> 20) MB)")
                }
                .listRowBackground(Desk.card)
                Section("Applications") {
                    Toggle("Rosetta (Intel apps)", isOn: $intelApps)
                        .disabled(henge_rosetta_available() == 0 && !intelApps)
                        .onChange(of: intelApps) { _, enabled in henge_vm_set_rosetta(enabled ? 1 : 0) }
                    LabeledContent("Current engine", value: henge_engine_rosetta() != 0 ? "Rosetta" : "Mainline")
                    if intelApps != (henge_engine_rosetta() != 0) {
                        Text("Quit Henge and reopen it to apply this change.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Text(henge_rosetta_available() != 0
                         ? "Experimental support. Intel apps run very slowly. Off uses the mainline engine; on uses the Rosetta engine. Quit and reopen Henge after changing this setting. macOS may ask to install Rosetta."
                         : "Rosetta is not available on this device yet. Leave it off to use the mainline engine.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Memory") {
                    LabeledContent("Extra memory", value: Entitlements.increasedMemory ? "On" : "Off")
                    LabeledContent("Henge's limit", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Free for Henge", value: ByteText.string(UInt64(henge_available_memory())))
                    Text(Entitlements.increasedMemory
                         ? "A Mac's memory is kept out of this limit once JIT is on. If iOS refuses that, it uses free storage instead."
                         : "This install isn't signed with the increased memory limit entitlement. Reinstall Henge with a certificate that has it. Export your Mac first if the reinstall replaces the app's data.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("Mouse and Trackpad") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pointer speed")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("Reverse scrolling", isOn: $reverseScrolling)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scroll speed")
                            Slider(value: $scrollSpeed, in: 0.1...1.5)
                        }
                        Text("A Magic Keyboard or a Bluetooth mouse moves the Mac's pointer. Pointer speed changes apply the next time a Mac starts; scroll speed changes apply immediately.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("Performance") {
                    Picker("Mac refresh rate", selection: $refreshRate) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Faster disk writes", isOn: $fastFlush)
                    Toggle("Quicker wake from idle", isOn: $wfiSpin)
                    Toggle("Superblocks (experimental)", isOn: $superblocks)
                    Picker("Code cache", selection: $codeCacheMB) {
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                    }
                    Text("A bigger code cache empties less often and takes more memory; Henge picks 1.5 GB where there is room for it. Applies the next time Henge opens. If JIT stops turning on, choose 1 GB.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("macOS draws a frame for every refresh: 30 Hz leaves the most of the emulated CPU to apps, at the cost of choppier animation; 60 Hz is smoother. Faster disk writes order them without waiting for a full sync; a sudden power loss could lose the last ones. Quicker wake keeps an idle CPU watching for work for 50 µs, at some battery cost. Superblocks let translated code run past conditional branches. Changes apply the next time a Mac starts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Log") {
                    ShareLink(item: HengeLog.logFileURL) { Label("Share henge.log", systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("Settings")
        }
    }
}
