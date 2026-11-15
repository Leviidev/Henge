import SwiftUI

enum WirelessControlMode: Int, CaseIterable, Identifiable {
    case touchpad, keyboard, gamepad
    var id: Int { rawValue }
    var title: String { ["Touchpad","Keyboard","Gamepad"][rawValue] }
    var icon: String { ["cursorarrow.motionlines","keyboard","gamecontroller"][rawValue] }
}

/// One transport and input surface for all controller modes. Posture changes
/// release held input; neither a second connection nor a display timer is used.
struct WirelessControlsPanel<Input: View>: View {
    let status: String
    let tuning: GamepadTuning
    var isDuo=false
    var acceptsInput=true
    var supportsVideo=false
    var enableVideo:()->Void = {}
    @Binding var mode: WirelessControlMode
    let disconnect: () -> Void
    let configure: () -> Void
    let sendPad: (GamepadState) -> Void
    let sendPointer: (LinkControl) -> Void
    let input: (WirelessControlMode) -> Input
    @AppStorage("henge.link.controllerLayout") private var layoutChoice = "automatic"
    var body: some View {
        GeometryReader { geometry in
            let choice=ControllerLayoutChoice(rawValue:layoutChoice) ?? .automatic
            let layout=ControllerPostureLayout(size:geometry.size,choice:choice,isDuo:isDuo,division:controllerDivision(geometry,isDuo:isDuo))
            Group {
                if mode == .gamepad && layout.style == .tabletop {
                    tabletop(layout)
                } else {
                    standard(wide:geometry.size.width>geometry.size.height*1.25,
                             short:geometry.size.height<450,portrait:layout.style == .portrait)
                }
            }
            .background(Desk.page)
            .foregroundStyle(Desk.text)
            .onChange(of:layout.style) { _,_ in releaseInput() }
            .onChange(of:layoutChoice) { _,_ in releaseInput() }
        }
    }
    private func releaseInput() { sendPad(.off);sendPointer(LinkControl(type:"release")) }
    private func standard(wide:Bool,short:Bool,portrait:Bool) -> some View {
        Group {
            if wide {
                HStack(spacing:14) {
                    Group {
                        if short { ScrollView(.vertical) { navigation(compact:true) }.scrollIndicators(.hidden) }
                        else { navigation(compact:false) }
                    }.frame(width:short ? 76 : 176)
                    content(portrait:portrait)
                }
            } else {
                VStack(spacing:12) { header;modePicker;content(portrait:portrait) }
            }
        }.padding(wide ? 14 : 18)
        .background(Desk.page)
    }
    private func tabletop(_ layout:ControllerPostureLayout) -> some View {
        VStack(spacing:0) {
            VStack(spacing:10) {
                header;modePicker
                pointingPad(identifier:"tabletop-touchpad")
            }.padding(14).frame(height:layout.upper.height)
            Color.clear.frame(height:layout.fold.height).allowsHitTesting(false)
            GamepadControllerSurface(tuning:tuning,acceptsInput:acceptsInput,showsTouchpad:false,send:sendPad,sendPointer:sendPointer)
                .padding(.horizontal,12).frame(height:layout.lower.height)
        }
    }
    private var header: some View {
        HStack(spacing:12) {
            Image(systemName:acceptsInput ? "wifi" : "wifi.exclamationmark").foregroundStyle(acceptsInput ? Desk.good : Desk.warn)
            VStack(alignment:.leading,spacing:3) {
                Text(isDuo ? "Duo wireless controls" : "Wireless controls").font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength:0)
            if isDuo && mode == .gamepad { layoutMenu }
            if supportsVideo { videoButton }
            settingsButton
            Button(action:disconnect) { Image(systemName:"xmark.circle.fill").font(.title2) }
                .accessibilityLabel("Disconnect wireless controls")
        }
    }
    private var modePicker: some View {
        Picker("Control mode",selection:$mode) {
            ForEach(WirelessControlMode.allCases) { control in Label(control.title,systemImage:control.icon).tag(control) }
        }.pickerStyle(.segmented)
    }
    private var layoutMenu: some View {
        Menu {
            Picker("Controller layout",selection:$layoutChoice) {
                ForEach(ControllerLayoutChoice.allCases) { Text($0.title).tag($0.rawValue) }
            }
        } label: { Image(systemName:"rectangle.split.1x2").frame(width:44,height:44) }
            .accessibilityLabel("Controller layout")
    }
    private func navigation(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            if !compact {
                Label("CONTROLLER", systemImage: "wifi")
                    .font(.caption.weight(.semibold)).tracking(0.6)
                    .foregroundStyle(acceptsInput ? Desk.good : Desk.warn)
                Text(status).font(.caption).foregroundStyle(Desk.dim).lineLimit(3)
                Divider().padding(.vertical, 2)
            }
            ForEach(WirelessControlMode.allCases) { control in
                Button { mode = control } label: {
                    Group {
                        if compact {
                            VStack(spacing: 5) { Image(systemName: control.icon).font(.title3); Text(control.title).font(.caption2) }
                        } else {
                            Label(control.title, systemImage: control.icon).font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: compact ? 52 : 50, alignment: compact ? .center : .leading)
                    .padding(.horizontal, compact ? 2 : 12)
                    .foregroundStyle(mode == control ? Desk.accentLight : Desk.dim)
                    .background(mode == control ? Desk.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityLabel(control.title)
                    .accessibilityAddTraits(mode == control ? .isSelected : [])
            }
            Spacer(minLength: 8)
            Group {
                if compact { VStack(spacing: 0) { navigationTools } }
                else { HStack(spacing: 0) { navigationTools } }
            }.foregroundStyle(Desk.dim)
            Button("Disconnect", systemImage: "xmark.circle", action: disconnect)
                .font(.caption.weight(.semibold)).foregroundStyle(Desk.bad)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding(compact ? 6 : 12)
        .background(Desk.card, in: RoundedRectangle(cornerRadius: 22))
    }
    @ViewBuilder private var navigationTools: some View {
        if isDuo && mode == .gamepad { layoutMenu }
        if supportsVideo { videoButton }
        settingsButton
    }
    private var videoButton:some View {
        Button(action:enableVideo) { Image(systemName:"video").frame(width:44,height:44) }.accessibilityLabel("Show Mac video with controls")
    }
    private var settingsButton: some View {
        Button(action:configure) { Image(systemName:"slider.horizontal.3").font(.title3).frame(width:44,height:44) }
            .accessibilityLabel("Controller sensitivity and layout settings")
    }
    private func pointingPad(identifier:String) -> some View {
        WirelessInputSurface(keyboard:false,send:sendPointer,acceptsInput:acceptsInput,identifier:identifier)
            .background(Desk.card,in:RoundedRectangle(cornerRadius:24))
            .overlay(alignment:.bottom) {
                Text("Touchpad · Tap to click · Two fingers scroll").font(.caption).foregroundStyle(.secondary).padding(10).allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.white.opacity(0.12)).allowsHitTesting(false))
    }
    @ViewBuilder private func content(portrait:Bool) -> some View {
        if mode == .gamepad {
            GamepadControllerSurface(tuning:tuning,acceptsInput:acceptsInput,portrait:portrait,capturesKeyboard:true,send:sendPad,sendPointer:sendPointer)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
        } else {
            VStack(alignment:.leading,spacing:10) {
                Label(mode == .keyboard ? "Keyboard + touchpad" : "Touchpad",systemImage:mode.icon).font(.title3.weight(.semibold))
                input(mode)
                    .disabled(!acceptsInput)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .background(Desk.card,in:RoundedRectangle(cornerRadius:24))
                    .overlay(RoundedRectangle(cornerRadius:24).strokeBorder(.white.opacity(0.12)).allowsHitTesting(false))
                Text(mode == .keyboard ? "Type below or use a hardware keyboard. The area above stays a touchpad." : "Tap to click · Two fingers scroll · Hold and drag moves windows")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
