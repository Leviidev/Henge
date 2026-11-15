import Foundation
import Combine

struct GamepadTuning: Codable, Equatable {
    var moveSensitivity = 1.0
    var lookSensitivity = 1.0
    var deadZone = 0.12
    var responseCurve = 1.25
    var invertLookY = false
    var mouseLookSpeed = 900.0
    var scale = 1.0
    var opacity = 0.6
    var normalized: Self {
        func bounded(_ x: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            x.isFinite ? min(range.upperBound,max(range.lowerBound,x)) : fallback
        }
        var t = self
        t.moveSensitivity = bounded(moveSensitivity,0.35...2,1)
        t.lookSensitivity = bounded(lookSensitivity,0.25...3,1)
        t.deadZone = bounded(deadZone,0...0.35,0.12)
        t.responseCurve = bounded(responseCurve,1...2.5,1.25)
        t.mouseLookSpeed = bounded(mouseLookSpeed,300...2400,900)
        t.scale = bounded(scale,0.8...1.15,1)
        t.opacity = bounded(opacity,0.25...0.85,0.6)
        return t
    }
    /// Circular travel and radial dead zone: diagonals have the same maximum
    /// magnitude as cardinals, with continuous travel outside the dead zone.
    func stick(x: Double, y: Double, right: Bool) -> (Int16,Int16) {
        guard x.isFinite, y.isFinite else { return (0,0) }
        let t = normalized, radius = hypot(x,y)
        guard radius > t.deadZone else { return (0,0) }
        let sensitivity = right ? t.lookSensitivity : t.moveSensitivity
        let travel = min(1,pow((min(1,radius)-t.deadZone)/(1-t.deadZone),t.responseCurve)*sensitivity)
        let vertical = right && t.invertLookY ? -1.0 : 1.0
        return (Int16((x/radius*travel*32767).rounded()),Int16((y/radius*travel*32767*vertical).rounded()))
    }
    static func hat(x: Double, y: Double) -> UInt8 {
        guard x.isFinite, y.isFinite, hypot(x,y)>0.22 else { return 8 }
        var angle = atan2(x,-y)
        if angle < 0 { angle += 2 * .pi }
        return UInt8(Int((angle / (.pi/4)).rounded()) % 8)
    }
}

@MainActor
final class GamepadPreferences: ObservableObject {
    static let shared = GamepadPreferences()
    @Published var value: GamepadTuning {
        didSet {
            if let data = try? JSONEncoder().encode(value.normalized) {
                UserDefaults.standard.set(data,forKey:"henge.gamepad.tuning.v1")
            }
        }
    }
    init() {
        if let data = UserDefaults.standard.data(forKey:"henge.gamepad.tuning.v1"),
           let saved = try? JSONDecoder().decode(GamepadTuning.self,from:data) { value = saved.normalized }
        else { value = GamepadTuning() }
    }
}
