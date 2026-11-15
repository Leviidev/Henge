import Foundation
import CoreGraphics

/// Transport-independent finger ownership and full-state production input model.
/// Drawing and UIKit events use this same model; tests need no synthetic UITouch.
struct PadInput {
    struct Finger { var control: PadControl; var point: CGPoint; var start: CGPoint }
    private(set) var fingers: [Int:Finger] = [:]
    func active(_ control: PadControl) -> Finger? { fingers.values.first { $0.control == control } }
    mutating func begin(_ id: Int, point: CGPoint, layout: PadLayout) {
        guard point.x.isFinite,point.y.isFinite,layout.bounds.contains(point),
              let control = PadControl.allCases.reversed().first(where:{layout.rect($0).contains(point)}),
              active(control) == nil else { return }
        fingers[id] = Finger(control:control,point:point,start:point)
    }
    mutating func move(_ id: Int, point: CGPoint) {
        guard point.x.isFinite,point.y.isFinite,var finger = fingers[id] else { return };finger.point=point;fingers[id]=finger
    }
    mutating func end(_ id: Int) { fingers.removeValue(forKey:id) }
    mutating func release() { fingers.removeAll() }
    func trigger(_ control: PadControl, layout: PadLayout) -> CGFloat {
        guard let finger=active(control) else { return 0 }
        return max(0,min(1,1-(finger.point.y-finger.start.y)/(layout.rect(control).height*0.9)))
    }
    func state(tuning: GamepadTuning, layout: PadLayout) -> GamepadState {
        var state=GamepadState();state.mouseSpeed=UInt16(tuning.normalized.mouseLookSpeed.rounded())
        for finger in fingers.values {
            let c=finger.control,r=layout.rect(c)
            if c == .move || c == .look {
                let axes=tuning.stick(x:Double((finger.point.x-r.midX)/(r.width*0.32)),y:Double((finger.point.y-r.midY)/(r.height*0.32)),right:c == .look)
                if c == .move { state.lx=axes.0;state.ly=axes.1 } else { state.rx=axes.0;state.ry=axes.1 }
            } else if c == .dpad {
                state.hat=GamepadTuning.hat(x:Double((finger.point.x-r.midX)/(r.width/2)),y:Double((finger.point.y-r.midY)/(r.height/2)))
            } else if c == .lt { state.left=UInt8((trigger(c,layout:layout)*255).rounded()) }
            else if c == .rt { state.right=UInt8((trigger(c,layout:layout)*255).rounded()) }
            else { state.buttons |= c.mask }
        }
        return state
    }
}
