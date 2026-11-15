import Foundation
import CoreGraphics

@main struct GamepadTuningChecks {
    @MainActor static func main() throws {
        let t = GamepadTuning()
        precondition(t.stick(x:0,y:0,right:false) == (0,0))
        precondition(t.stick(x:0.1,y:0,right:false) == (0,0))
        let cardinal=t.stick(x:1,y:0,right:false), diagonal=t.stick(x:1,y:1,right:false)
        precondition(cardinal.0==32767 && cardinal.1==0)
        precondition(hypot(Double(diagonal.0),Double(diagonal.1))<=32768)
        precondition(t.stick(x:.infinity,y:0,right:true)==(0,0))
        var inverted=t;inverted.invertLookY=true
        precondition(inverted.stick(x:0,y:1,right:true).1 == -32767)
        precondition(inverted.stick(x:0,y:1,right:false).1 == 32767)
        var precise=t;precise.lookSensitivity=0.25
        precondition(precise.stick(x:1,y:0,right:true).0 < cardinal.0)
        var broken=t;broken.deadZone = .nan;broken.scale = .infinity;broken.mouseLookSpeed = -1
        precondition(broken.normalized.deadZone==0.12 && broken.normalized.scale==1 && broken.normalized.mouseLookSpeed==300)
        for i in 0..<8 {
            let angle=Double(i)*Double.pi/4
            precondition(GamepadTuning.hat(x:sin(angle),y:-cos(angle))==UInt8(i))
        }
        precondition(GamepadTuning.hat(x:0,y:0)==8)
        for size in [CGSize(width:951,height:669),CGSize(width:1376,height:1032),CGSize(width:390,height:844),CGSize(width:844,height:390),CGSize(width:320,height:200)] {
            for portrait in [false,true] {
            for scale in [0.8,1,1.15] {
                let bounds=CGRect(origin:.zero,size:size),layout=PadLayout(bounds:bounds,size:scale,portrait:portrait)
                for control in PadControl.allCases {
                    let rect=layout.rect(control)
                    precondition(!rect.intersects(layout.touchpadRect),"touchpad overlaps \(control)")
                    precondition(rect.width>0 && rect.height>0 && bounds.contains(rect),"out of bounds \(control) at \(size)")
                    for other in PadControl.allCases where other.rawValue>control.rawValue {
                        precondition(!rect.intersects(layout.rect(other)),"overlap \(control)/\(other) at \(size)")
                    }
                }
            }
        }
        }
        let touchLayout=PadLayout(bounds:CGRect(x:0,y:0,width:951,height:320),size:1)
        func center(_ control: PadControl) -> CGPoint { let r=touchLayout.rect(control);return CGPoint(x:r.midX,y:r.midY) }
        var input=PadInput()
        input.begin(1,point:center(.move),layout:touchLayout)
        input.begin(2,point:center(.look),layout:touchLayout)
        input.begin(3,point:center(.a),layout:touchLayout)
        input.begin(4,point:center(.rt),layout:touchLayout)
        input.begin(5,point:center(.a),layout:touchLayout) // duplicate control owner is ignored
        var point=center(.move);point.x += 1000;input.move(1,point:point)
        point=center(.look);point.y -= 1000;input.move(2,point:point)
        var live=input.state(tuning:t,layout:touchLayout)
        precondition(live.lx==32767 && live.ry == -32767 && live.buttons==1 && live.right==255)
        input.end(5);precondition(input.state(tuning:t,layout:touchLayout).buttons==1)
        point=center(.rt);point.y += touchLayout.rect(.rt).height*0.45;input.move(4,point:point)
        precondition(abs(Int(input.state(tuning:t,layout:touchLayout).right)-128)<=1)
        input.end(3);live=input.state(tuning:t,layout:touchLayout)
        precondition(live.buttons==0 && live.lx==32767 && live.ry == -32767)
        input.release();live=input.state(tuning:t,layout:touchLayout)
        precondition(live.buttons==0 && live.lx==0 && live.ry==0 && live.right==0 && live.hat==8)
        let local=GamepadState(lx:12000), remote=GamepadState(ly:16000,rx:2000,mouseSpeed:1400)
        let merged=GamepadState.merged(local,remote)
        precondition(merged.lx==12000 && merged.ly==0 && merged.rx==2000 && merged.mouseSpeed==1400)
        precondition(GamepadState.merged(.off,remote)==remote)
        let old=Data(#"{"connected":true,"buttons":0,"hat":8,"lx":0,"ly":0,"rx":0,"ry":0,"left":0,"right":0}"#.utf8)
        let oldDecoded=try JSONDecoder().decode(GamepadState.self,from:old)
        precondition(oldDecoded.mouseSpeed==nil)
        precondition(!GamepadState(mouseSpeed:299).valid && !GamepadState(mouseSpeed:2401).valid)
        let decoded=try JSONDecoder().decode(GamepadState.self,from:JSONEncoder().encode(remote))
        precondition(decoded==remote)
        var steering=GyroSteeringMath()
        precondition(steering.update(angle:0,time:1,fullLockDegrees:35,inverted:false)==0)
        for frame in 1...120 { _=steering.update(angle:Double.pi/3,time:1+Double(frame)/60,fullLockDegrees:35,inverted:false) }
        precondition(steering.update(angle:Double.pi/3,time:4,fullLockDegrees:35,inverted:false)>32000)
        let throttle=GamepadState(buttons:1,lx:1000,ly:-20000,rx:500,ry:200,left:0,right:255)
        let driven=GyroSteeringMath.merge(throttle,steering:-20000,enabled:true)
        precondition(driven.lx == -20000 && driven.ly == throttle.ly && driven.rx == 500 && driven.right == 255 && driven.buttons == 1)
        precondition(driven.mappedKeys.contains(4) && driven.mappedKeys.contains(26))
        precondition(GyroSteeringMath.merge(throttle,steering:20000,enabled:false)==throttle)
        precondition(GyroSteeringMath.merge(.off,steering:20000,enabled:true) == .off)
        precondition(steering.update(angle:.nan,time:4,fullLockDegrees:35,inverted:false)==0)
        precondition(steering.update(angle:0.001,time:5,fullLockDegrees:35,inverted:false)==0)
        var motion=TouchpadMotion()
        for _ in 0..<7 { precondition(motion.consume(dx:0.5,dy:-0.5,multiplier:0.25)==(0,0)) }
        precondition(motion.consume(dx:0.5,dy:-0.5,multiplier:0.25)==(1,-1))
        _=motion.consume(dx:0.5,dy:0.5,multiplier:1);motion.reset()
        precondition(motion.consume(dx:0.5,dy:0.5,multiplier:1)==(0,0))
        precondition(motion.consume(dx:.nan,dy:0,multiplier:1)==(0,0))
        precondition(motion.consume(dx:1e99,dy:-1e99,multiplier:3)==(4096,-4096))
        precondition(TouchpadTuning(pointerSpeed:.infinity,scrollSpeed:-1).normalized == TouchpadTuning(pointerSpeed:1,scrollSpeed:0.25))
        let suite="henge.touchpad-test.\(UUID().uuidString)",defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let saved=TouchpadPreferences(defaults:defaults)
        saved.value=TouchpadTuning(pointerSpeed:2.5,scrollSpeed:0.5)
        precondition(TouchpadPreferences(defaults:defaults).value==saved.value)
        defaults.set(Data("invalid".utf8),forKey:"henge.touchpad.tuning.v1")
        precondition(TouchpadPreferences(defaults:defaults).value==TouchpadTuning())
        let tall=CGSize(width:669,height:951),fold=CGRect(x:0,y:455.5,width:669,height:40)
        let automatic=ControllerPostureLayout(size:tall,choice:.automatic,isDuo:true,division:fold)
        precondition(automatic.style == .tabletop && automatic.upper.maxY==fold.minY && automatic.lower.minY==fold.maxY)
        precondition(ControllerPostureLayout(size:tall,choice:.automatic,isDuo:false,division:fold).style == .portrait)
        precondition(ControllerPostureLayout(size:tall,choice:.standard,isDuo:true,division:fold).style == .standard)
        precondition(ControllerPostureLayout(size:tall,choice:.automatic,isDuo:true,division:nil).style == .portrait)
        precondition(ControllerPostureLayout(size:CGSize(width:951,height:669),choice:.automatic,isDuo:true,division:CGRect(x:455,y:0,width:40,height:669)).style == .standard)
        precondition(ControllerPostureLayout(size:CGSize(width:390,height:300),choice:.tabletop,isDuo:true,division:nil).style == .standard)
        let manual=ControllerPostureLayout(size:tall,choice:.tabletop,isDuo:true,division:nil)
        precondition(manual.style == .tabletop && manual.lower.minY>manual.upper.maxY)
        print("Gamepad tuning: radial response, inversion, sensitivity, bounded values, eight-way hat, unfolded Duo/M4/compact non-overlapping layouts, whole-stick arbitration and additive wire compatibility passed")
    }
}
