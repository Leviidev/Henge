import SwiftUI
import UIKit

/// The controller and pointing pad share existing input paths. No extra ticker.
struct GamepadControllerSurface: View {
    let tuning:GamepadTuning
    var acceptsInput=true
    var portrait=false
    var showsTouchpad=true
    var capturesKeyboard=false
    let send:(GamepadState)->Void
    let sendPointer:(LinkControl)->Void
    @ObservedObject private var gyro=GyroSteeringService.shared
    @ObservedObject private var touchpad=TouchpadPreferences.shared
    @Environment(\.scenePhase) private var phase
    @State private var owner=UUID()
    @State private var latest=GamepadState()
    private func publish(_ state:GamepadState) {
        latest=state
        guard phase == .active && acceptsInput else { send(.off);return }
        send(GyroSteeringMath.merge(state,steering:gyro.axis,enabled:gyro.steering && gyro.owns(owner)))
    }
    var body:some View {
        ControllerInputCanvas(tuning:tuning,portrait:portrait,showsTouchpad:showsTouchpad,
                              capturesKeyboard:capturesKeyboard,acceptsInput:acceptsInput && phase == .active,
                              touchpadTuning:touchpad.value,send:publish,sendPointer:sendPointer)
        .overlay(alignment:.top) {
            if gyro.enabled {
                Button { gyro.calibrate() } label: {
                    Label("Recenter",systemImage:"steeringwheel").font(.caption).padding(.horizontal,10).frame(height:28).background(.ultraThinMaterial,in:Capsule())
                }.accessibilityLabel("Recenter gyro steering")
            }
        }
        .onAppear { gyro.acquire(owner);gyro.setForeground(phase == .active && acceptsInput,owner:owner) }
        .onDisappear { gyro.release(owner);send(.off) }
        .onChange(of:phase) { _,value in gyro.setForeground(value == .active && acceptsInput,owner:owner) }
        .onChange(of:acceptsInput) { _,value in
            gyro.setForeground(phase == .active && value,owner:owner)
            if !value { latest = .off;send(.off);sendPointer(LinkControl(type:"release")) }
        }
        .onChange(of:gyro.axis) { _,_ in if gyro.owns(owner) { publish(latest) } }
        .onChange(of:gyro.enabled) { _,_ in if gyro.owns(owner) { publish(latest) } }
    }
}

/// One native coordinate space for the controls and their pointing surface.
/// UIKit owns both subview frames and hit testing; no offset representable can
/// be clipped by a separately proposed SwiftUI hit region on compact layouts.
private struct ControllerInputCanvas:UIViewRepresentable {
    let tuning:GamepadTuning
    let portrait:Bool
    let showsTouchpad:Bool
    let capturesKeyboard:Bool
    let acceptsInput:Bool
    let touchpadTuning:TouchpadTuning
    let send:(GamepadState)->Void
    let sendPointer:(LinkControl)->Void
    func makeUIView(context:Context)->ControllerCanvasView {
        let view=ControllerCanvasView();updateUIView(view,context:context);return view
    }
    func updateUIView(_ view:ControllerCanvasView,context:Context) {
        view.pad.send=send;view.pointer.send=sendPointer
        view.configure(tuning:tuning,portrait:portrait,showsTouchpad:showsTouchpad,
                       capturesKeyboard:capturesKeyboard,acceptsInput:acceptsInput && context.environment.isEnabled,
                       pointerTuning:touchpadTuning)
    }
    static func dismantleUIView(_ view:ControllerCanvasView,coordinator:()) {
        view.pad.release();view.pointer.releaseInput();view.pointer.resignFirstResponder()
        view.pad.send=nil;view.pointer.send=nil
    }
}
private final class ControllerCanvasView:UIView {
    let pad=PadView()
    let pointer=LinkInputView()
    private let caption=UILabel()
    private var tuning=GamepadTuning(),portrait=false,shown=true
    override init(frame:CGRect) {
        super.init(frame:frame);backgroundColor = .clear;isMultipleTouchEnabled=true
        addSubview(pad);addSubview(pointer)
        pointer.accessibilityIdentifier="gamepad-touchpad"
        pointer.accessibilityLabel="Gamepad touchpad"
        pointer.layer.cornerRadius=12;pointer.layer.borderWidth=1
        pointer.layer.borderColor=UIColor.white.withAlphaComponent(0.35).cgColor
        caption.text="Touchpad";caption.font = .systemFont(ofSize:10)
        caption.textColor=UIColor.secondaryLabel;caption.textAlignment = .center
        caption.isUserInteractionEnabled=false;caption.isAccessibilityElement=false
        pointer.addSubview(caption)
    }
    required init?(coder:NSCoder) { fatalError("made in code") }
    func configure(tuning:GamepadTuning,portrait:Bool,showsTouchpad:Bool,capturesKeyboard:Bool,acceptsInput:Bool,pointerTuning:TouchpadTuning) {
        self.tuning=tuning.normalized;self.portrait=portrait;self.shown=showsTouchpad
        pad.configure(tuning,portrait:portrait,acceptsInput:acceptsInput)
        pointer.capturesKeyboard=capturesKeyboard;pointer.acceptsInput=acceptsInput && showsTouchpad
        pointer.pointerTuning=pointerTuning;pointer.isHidden = !showsTouchpad
        pointer.backgroundColor=UIColor.black.withAlphaComponent(self.tuning.opacity)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews();pad.frame=bounds
        let frame=PadLayout(bounds:bounds,size:tuning.scale,portrait:portrait).touchpadRect
        if pointer.frame != .zero && pointer.frame != frame {
            pointer.releaseInput()
            for gesture in pointer.gestureRecognizers ?? [] where gesture.isEnabled {
                gesture.isEnabled=false;gesture.isEnabled=true
            }
        }
        pointer.frame=frame
        caption.frame=CGRect(x:4,y:max(0,frame.height-19),width:max(0,frame.width-8),height:15)
    }
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool {
        if shown && pointer.isUserInteractionEnabled && pointer.frame.contains(point) { return true }
        return pad.point(inside:convert(point,to:pad),with:event)
    }
}
