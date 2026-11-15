import Foundation
import Combine
import CoreMotion

/// One opt-in motion owner. No sensor, timer or network work when disabled,
/// backgrounded, disconnected or outside the gamepad view.
@MainActor final class GyroSteeringService: ObservableObject {
    static let shared=GyroSteeringService()
    @Published var enabled=false { didSet { if oldValue != enabled { reconcile() } } }
    @Published private(set) var axis:Int16=0
    @Published private(set) var status="Gyro off"
    @Published var fullLockDegrees:Double=UserDefaults.standard.object(forKey:"henge.gyro.lock") as? Double ?? 35 {
        didSet { UserDefaults.standard.set(fullLockDegrees.isFinite ? min(70,max(15,fullLockDegrees)) : 35,forKey:"henge.gyro.lock");calibrate() }
    }
    @Published var inverted=UserDefaults.standard.bool(forKey:"henge.gyro.inverted") {
        didSet { UserDefaults.standard.set(inverted,forKey:"henge.gyro.inverted");calibrate() }
    }
    private let motion=CMMotionManager()
    private var reference:CMAttitude?
    private var math=GyroSteeringMath()
    private var owner:UUID?
    private var foreground=true
    private var configuring=false
    private var generation=UUID()
    var available:Bool { motion.isDeviceMotionAvailable }
    var steering:Bool { enabled && available && owner != nil && foreground && !configuring }
    func acquire(_ id:UUID) { owner=id;foreground=true;reconcile() }
    func release(_ id:UUID) { guard owner==id else { return };owner=nil;reconcile() }
    func setForeground(_ active:Bool,owner id:UUID) { guard owner==id else { return };foreground=active;reconcile() }
    func owns(_ id:UUID)->Bool { owner==id }
    func setConfigurationVisible(_ visible:Bool) { configuring=visible;reconcile() }
    func calibrate() { reference=nil;math.reset();axis=0 }
    private func reconcile() {
        motion.stopDeviceMotionUpdates();generation=UUID();calibrate()
        guard steering else { status=available ? "Gyro off" : "Motion sensor unavailable";return }
        status="Hold comfortably · calibrating…"
        motion.deviceMotionUpdateInterval=1/60
        let stamp=generation
        motion.startDeviceMotionUpdates(to:.main) { [weak self] sample,error in
            MainActor.assumeIsolated {
                guard let self,self.generation==stamp,self.steering else { return }
                guard error==nil,let sample else { self.enabled=false;self.status="Motion unavailable; joystick steering restored";return }
                guard let reference=self.reference else {
                    self.reference=sample.attitude.copy() as? CMAttitude;self.status="Tilt to steer";return
                }
                guard let relative=sample.attitude.copy() as? CMAttitude else { return }
                relative.multiply(byInverseOf:reference)
                let q=relative.quaternion
                let angle=atan2(2*(q.w*q.z+q.x*q.y),1-2*(q.y*q.y+q.z*q.z))
                let next=self.math.update(angle:angle,time:sample.timestamp,fullLockDegrees:self.fullLockDegrees,inverted:self.inverted)
                if next==0 || abs(Int(next)-Int(self.axis))>=32 { self.axis=next }
            }
        }
    }
}
