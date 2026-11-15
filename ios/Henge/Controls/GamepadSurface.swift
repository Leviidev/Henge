import SwiftUI
import UIKit

/// Native multitouch controls. Finger ownership survives drags beyond a control;
/// untouched transparent space passes through to the desktop beneath the overlay.
struct GamepadSurface: UIViewRepresentable {
    var tuning = GamepadTuning()
    var portrait = false
    var acceptsInput = true
    var send: (GamepadState) -> Void
    func makeUIView(context: Context) -> PadView {
        let view = PadView(); view.send = send; view.configure(tuning,portrait:portrait,acceptsInput:acceptsInput && context.environment.isEnabled); return view
    }
    func updateUIView(_ view: PadView, context: Context) { view.send = send; view.configure(tuning,portrait:portrait,acceptsInput:acceptsInput && context.environment.isEnabled) }
    static func dismantleUIView(_ view: PadView, coordinator: ()) { view.release(); view.send = nil }
}

final class PadView: UIView {
    var send: ((GamepadState) -> Void)?
    private var input = PadInput()
    private var previousBounds = CGRect.null
    private var tuning = GamepadTuning()
    private var portrait = false
    private var acceptsInput = true
    private var lastSent = GamepadState.off
    private var current = GamepadState()
#if DEBUG
    private var debugEvents: [String] = []
    private func debugRecord(_ name: String) {
        debugEvents.append(name)
        if debugEvents.count>12 { debugEvents.removeFirst(debugEvents.count-12) }
        accessibilityValue=debugEvents.joined(separator:" | ")
    }
#endif
    override init(frame: CGRect) {
        super.init(frame:frame); isMultipleTouchEnabled = true; isOpaque = false; backgroundColor = .clear
        isAccessibilityElement = true;accessibilityIdentifier="gamepad-surface"
        accessibilityTraits.insert(.allowsDirectInteraction)
        accessibilityLabel = "Virtual gamepad: two sticks, directional pad, face buttons, analog triggers, shoulders and stick clicks."
        accessibilityHint = "Use the three-finger controls menu for gamepad settings or to hide the gamepad."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func configure(_ value: GamepadTuning, portrait: Bool, acceptsInput: Bool) {
        let value = value.normalized
        guard value != tuning || self.portrait != portrait || self.acceptsInput != acceptsInput else { return }
        tuning = value;self.portrait=portrait;self.acceptsInput=acceptsInput
        isUserInteractionEnabled=acceptsInput
        if !acceptsInput { release();return }
        if window != nil { cancelTouches() } else { input.release();setNeedsDisplay() }
    }
    private var layout: PadLayout { PadLayout(bounds:bounds,size:tuning.scale,portrait:portrait) }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard acceptsInput,bounds.contains(point) else { return false }
        return PadControl.allCases.contains { layout.rect($0).contains(point) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // SwiftUI may lay out again after an input callback. Preserve held
        // fingers unless the actual geometry changes (rotation/unfold/resize).
        guard bounds != previousBounds else { return }
        previousBounds = bounds
#if DEBUG
        debugRecord("bounds=\(bounds)")
#endif
        if !input.fingers.isEmpty { cancelTouches() }
        setNeedsDisplay()
    }
    private func active(_ control: PadControl) -> PadInput.Finger? { input.active(control) }
    private func trigger(_ control: PadControl) -> CGFloat { input.trigger(control,layout:layout) }
    private func drawText(_ text: String, in rect: CGRect, color: UIColor = .white, size: CGFloat = 14) {
        let style: [NSAttributedString.Key:Any] = [.font:UIFont.systemFont(ofSize:max(10,size*layout.scale),weight:.semibold),.foregroundColor:color]
        let extent = (text as NSString).size(withAttributes:style)
        (text as NSString).draw(at:CGPoint(x:rect.midX-extent.width/2,y:rect.midY-extent.height/2),withAttributes:style)
    }
    override func draw(_ rect: CGRect) {
        for control in PadControl.allCases {
            let r = layout.rect(control), down = active(control) != nil
            let stick = control == .move || control == .look
            let face = [.a, .b, .x, .y].contains(control)
            let shape = UIBezierPath(roundedRect:r,cornerRadius:stick || face ? r.width/2 : min(16*layout.scale,r.height/2))
            let tint: UIColor = control == .a ? .systemGreen : control == .b ? .systemRed : control == .x ? .systemBlue : control == .y ? .systemYellow : .systemBlue
            UIColor(white: down ? 0.2 : 0.09, alpha: tuning.opacity).setFill(); shape.fill()
            if face { tint.withAlphaComponent(down ? 0.45 : 0.14).setFill(); shape.fill() }
            UIColor.white.withAlphaComponent(down ? 0.85 : 0.35).setStroke(); shape.lineWidth = max(1,1.5*layout.scale); shape.stroke()
            if stick {
                if let finger = active(control) {
                    var dx = finger.point.x-r.midX, dy = finger.point.y-r.midY
                    let distance = hypot(dx,dy), limit = r.width*0.32
                    if distance > limit { dx *= limit/distance; dy *= limit/distance }
                    let thumb = CGRect(x:r.midX+dx-r.width*0.23,y:r.midY+dy-r.height*0.23,width:r.width*0.46,height:r.height*0.46)
                    UIColor.systemBlue.withAlphaComponent(0.8).setFill(); UIBezierPath(ovalIn:thumb).fill()
                } else {
                    UIColor.white.withAlphaComponent(0.2).setFill(); UIBezierPath(ovalIn:r.insetBy(dx:r.width*0.27,dy:r.height*0.27)).fill()
                }
                drawText(control.label,in:CGRect(x:r.minX,y:r.maxY-24*layout.scale,width:r.width,height:20*layout.scale),size:11)
            } else if control == .dpad {
                let cx = r.midX, cy = r.midY, step = r.width*0.3
                for (label,x,y) in [("▲",cx,cy-step),("▶",cx+step,cy),("▼",cx,cy+step),("◀",cx-step,cy)] {
                    drawText(label,in:CGRect(x:x-12*layout.scale,y:y-12*layout.scale,width:24*layout.scale,height:24*layout.scale),size:13)
                }
                if current.hat < 8 {
                    let angle = CGFloat(current.hat)*CGFloat.pi/4
                    let dot = CGRect(x:cx+sin(angle)*step-4,y:cy-cos(angle)*step-4,width:8,height:8)
                    UIColor.systemBlue.setFill(); UIBezierPath(ovalIn:dot).fill()
                }
            } else {
                if control == .lt || control == .rt {
                    let amount = trigger(control)
                    UIColor.systemBlue.withAlphaComponent(0.65).setFill()
                    UIBezierPath(roundedRect:CGRect(x:r.minX+3,y:r.maxY-(r.height-6)*amount-3,width:r.width-6,height:(r.height-6)*amount),cornerRadius:10*layout.scale).fill()
                } else if down { UIColor.systemBlue.withAlphaComponent(0.5).setFill(); shape.fill() }
                let color: UIColor = control == .a ? .systemGreen : control == .b ? .systemRed : control == .x ? .systemCyan : control == .y ? .systemYellow : .white
                drawText(control.label,in:r,color:color,size:control.rawValue >= PadControl.menu.rawValue ? 10 : 16)
            }
        }
    }
    override func touchesBegan(_ touches: Set<UITouch>,with event: UIEvent?) {
        guard acceptsInput else { return }
        for touch in touches { input.begin(Int(bitPattern:ObjectIdentifier(touch)),point:touch.location(in:self),layout:layout) }
#if DEBUG
        debugRecord("begin=\(touches.first?.location(in:self) ?? .zero), owners=\(input.fingers.values.map{$0.control.rawValue})")
#endif
        publish()
    }
    override func touchesMoved(_ touches: Set<UITouch>,with event: UIEvent?) {
        for touch in touches { input.move(Int(bitPattern:ObjectIdentifier(touch)),point:touch.location(in:self)) }
#if DEBUG
        debugRecord("move=\(touches.first?.location(in:self) ?? .zero), owners=\(input.fingers.values.map{$0.control.rawValue})")
#endif
        publish()
    }
    override func touchesEnded(_ touches: Set<UITouch>,with event: UIEvent?) {
        for touch in touches { input.end(Int(bitPattern:ObjectIdentifier(touch))) }
#if DEBUG
        debugRecord("end")
#endif
        publish()
    }
    override func touchesCancelled(_ touches: Set<UITouch>,with event: UIEvent?) { touchesEnded(touches,with:event) }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { release() } else { publish() } }
    func release() { input.release();current = .off;emit(.off);setNeedsDisplay() }
    private func cancelTouches() {
#if DEBUG
        debugRecord("layout/tuning release")
#endif
        input.release();publish()
    }
    private func emit(_ state: GamepadState) { guard state != lastSent else { return };lastSent=state;send?(state) }
    private func publish() {
        let state=input.state(tuning:tuning,layout:layout);current=state;emit(state);setNeedsDisplay()
    }
}

#Preview("Gamepad · landscape") {
    ZStack { Color.gray; GamepadSurface(tuning:GamepadTuning(),send:{_ in}).frame(height:320) }.frame(width:844,height:390)
}
#Preview("Gamepad · compact") {
    ZStack { Color.gray; GamepadSurface(tuning:GamepadTuning(),send:{_ in}).frame(height:320) }.frame(width:390,height:600)
}
