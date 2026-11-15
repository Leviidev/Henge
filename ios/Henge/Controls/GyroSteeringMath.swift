import Foundation

/// Rotation about the calibrated screen's normal, with a small center deadband.
/// Horizontal steering replaces LX only; throttle/brake (LY) and all buttons stay.
struct GyroSteeringMath {
    private var filtered=0.0
    private var last:Double?
    mutating func reset() { filtered=0;last=nil }
    mutating func update(angle:Double,time:Double,fullLockDegrees:Double,inverted:Bool)->Int16 {
        guard angle.isFinite,time.isFinite,fullLockDegrees.isFinite else { reset();return 0 }
        let full=min(70,max(15,fullLockDegrees))*Double.pi/180
        let bounded=min(1,max(-1,atan2(sin(angle),cos(angle))/full))
        let dead=0.04
        let target=abs(bounded)<=dead ? 0 : (bounded<0 ? -1.0 : 1.0)*(abs(bounded)-dead)/(1-dead)
        let dt=last.map { min(0.1,max(0,time-$0)) } ?? 1/60.0
        last=time
        filtered += (target-filtered)*(1-exp(-dt/0.04))
        if target==0 && abs(filtered)<0.005 { filtered=0 }
        let result=Int16((min(1,max(-1,filtered))*(inverted ? -32767 : 32767)).rounded())
        return result
    }
    static func merge(_ pad:GamepadState,steering:Int16,enabled:Bool)->GamepadState {
        guard enabled,pad.connected else { return pad }
        var result=pad;result.lx=steering;return result
    }
}
