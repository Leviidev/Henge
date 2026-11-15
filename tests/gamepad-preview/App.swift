import SwiftUI
import Metal
import UIKit

@main struct GamepadPreviewApp: App {
    init() {
        try? FileManager.default.removeItem(at:URL.documentsDirectory.appendingPathComponent("ControlsWindowProof",isDirectory:true))
        for key in ["henge.gamepad.tuning.v1","henge.touchpad.tuning.v1","henge.link.controllerLayout"] { UserDefaults.standard.removeObject(forKey:key) }
    }
    var body: some Scene { WindowGroup { PreviewRoot() } }
}

struct PreviewRoot: View {
    @State private var opening=false
    @State private var homeState=0
    @State private var homeDark=true
    @State private var automaticSave=true
    @State private var homeActions=0
    @State private var wireless=false
    @State private var folded=false
    @State private var video=false
    @State private var settings=false
    @State private var mapping=false
    @State private var mode=WirelessControlMode.gamepad
    @State private var last=GamepadState.off
    @State private var presses=0
    @State private var maxLeft=0
    @State private var pointerMoves=0
    @State private var keyPresses=0
    @State private var proofCount=0
    @State private var proofError=""
    @ObservedObject private var preferences=GamepadPreferences.shared
    private func point(_ control:LinkControl) {
        if control.type == "move" { pointerMoves += 1 }
        if control.type == "key" && control.down == true { keyPresses += 1 }
    }
    private func receive(_ state: GamepadState) {
        if state.buttons&1 != 0 && last.buttons&1 == 0 { presses += 1 }
        maxLeft=max(maxLeft,abs(Int(state.lx)))
        last=state
    }
    @MainActor private func saveWindowProof() {
        do {
            guard let scene=UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window=scene.windows.first(where: \.isKeyWindow) else { throw CocoaError(.fileNoSuchFile) }
            let image=UIGraphicsImageRenderer(bounds:window.bounds).image { context in
                window.layer.render(in:context.cgContext)
            }
            guard let bytes=image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            let folder=URL.documentsDirectory.appendingPathComponent("ControlsWindowProof",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try bytes.write(to:folder.appendingPathComponent(String(format:"%02d.png",proofCount+1)),options:.atomic)
            proofCount += 1;proofError=""
        } catch { proofError="Window proof: \(error.localizedDescription)" }
    }
    var body: some View {
        GeometryReader { geometry in
            let width=min(folded ? 390 : PreviewFixture.viewport.width,max(1,geometry.size.width-24))
            let height=min(folded ? 844 : PreviewFixture.viewport.height,max(1,geometry.size.height-100))
            VStack(spacing:8) {
                HStack {
                    Text("\(PreviewFixture.profile) · layout fixture").font(.caption)
                    Spacer()
                    Button(opening ? "Controls" : "Home") { opening.toggle() }.accessibilityIdentifier("show-home")
                    if opening {
                        Button("State") { homeState=(homeState+1)%4 }.accessibilityIdentifier("home-state")
                        Button(homeDark ? "Light" : "Dark") { homeDark.toggle() }.accessibilityIdentifier("home-theme")
                    }
                    Button(wireless ? "Local" : "Wireless") { last = .off;wireless.toggle() }.accessibilityIdentifier("switch-layout")
                    if PreviewFixture.profile == "duo-unfolded" {
                        Button(folded ? "Unfold" : "Fold") { last = .off;folded.toggle() }.accessibilityIdentifier("fold")
                    }
                    if wireless { Button(video ? "Video off" : "Video") { video.toggle() }.accessibilityIdentifier("video") }
                    Button("Settings") { settings=true }.accessibilityIdentifier("settings")
                    Button { saveWindowProof() } label: { Image(systemName:"camera") }.accessibilityIdentifier("capture-window-proof")
                }
                HStack {
                    Text("A presses: \(presses)").accessibilityIdentifier("a-count")
                    Text("Left maximum: \(maxLeft)").accessibilityIdentifier("left-max").accessibilityValue(Text(verbatim:String(maxLeft)))
                    Text("Buttons: \(last.buttons)").accessibilityIdentifier("buttons")
                    Text("Moves: \(pointerMoves)").accessibilityIdentifier("moves").accessibilityValue(Text(verbatim:String(pointerMoves)))
                    Text("Keys: \(keyPresses)").accessibilityIdentifier("keys").accessibilityValue(Text(verbatim:String(keyPresses)))
                    Text(proofError.isEmpty ? "Proof: \(proofCount)" : proofError).accessibilityIdentifier("window-proof-status").accessibilityValue(Text(verbatim:String(proofCount)))
                }.font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5).frame(height:22)
                ZStack(alignment:.bottom) {
                    LinearGradient(colors:[.indigo.opacity(0.45),.gray.opacity(0.2),.black],startPoint:.topLeading,endPoint:.bottomTrailing)
                    if opening {
                        ScrollView {
                            OpeningDashboard(wide:width>=900) {
                                MacLaunchCard(name:"Macintosh",summary:"macOS · 8 GB · 4 CPUs",ready:homeState != 2,saved:homeState == 1,inMemory:homeState == 3,
                                    setupNote:"Enable JIT to start your Mac",start:{homeActions+=1},setup:{homeActions+=1},configure:{homeActions+=1})
                            } connections: {
                                VStack(spacing:20) {
                                    WorkspaceConnections(canExtend:true,controls:{homeActions+=1},display:{homeActions+=1},extend:{homeActions+=1})
                                    AutomaticSaveCard(enabled:$automaticSave)
                                    Text("Actions: \(homeActions)").accessibilityIdentifier("home-actions")
                                }
                            }.padding(18)
                        }.background(Desk.page)
                    } else if wireless && video {
                        WirelessVideoControls(isDuo:PreviewFixture.profile == "duo-unfolded",tuning:preferences.value,sendPad:receive,sendPointer:point,
                            video:ZStack { Color.indigo.opacity(0.5);Text("Video layout fixture · production controls").accessibilityIdentifier("video-fixture") },
                            toolbar:Text("Main Mac screen · fixture").font(.caption))
                    } else if wireless {
                        WirelessControlsPanel(status:"Connected · preview fixture",tuning:preferences.value,isDuo:PreviewFixture.profile == "duo-unfolded",mode:$mode,
                            disconnect:{last = .off},configure:{settings=true},sendPad:receive,sendPointer:point) { selected in
                                WirelessInputSurface(keyboard:selected == .keyboard,send:point)
                            }
                    } else {
                        VStack { Text("Mac display · overlay preview").foregroundStyle(.secondary).padding();Spacer();GamepadControllerSurface(tuning:preferences.value,send:receive,sendPointer:point).frame(height:320*preferences.value.normalized.scale) }
                    }
                }
                .frame(width:width,height:height)
                Spacer(minLength:0)
            }.padding(12).frame(width:geometry.size.width,height:geometry.size.height)
            .sheet(isPresented:$settings) { GamepadSettingsPanel(mapping:$mapping,allowsNativeProfile:!wireless) }
            .preferredColorScheme(opening && !homeDark ? .light : .dark)
        }
    }
}
