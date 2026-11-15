import Foundation
import Combine

struct TouchpadTuning: Codable, Equatable {
    var pointerSpeed = 1.0
    var scrollSpeed = 1.0
    var normalized: Self {
        var result=self
        result.pointerSpeed=pointerSpeed.isFinite ? min(3,max(0.25,pointerSpeed)) : 1
        result.scrollSpeed=scrollSpeed.isFinite ? min(3,max(0.25,scrollSpeed)) : 1
        return result
    }
}

/// Retain fractional motion without timers; reset between gestures or settings.
struct TouchpadMotion {
    private var x=0.0,y=0.0
    mutating func reset() { x=0;y=0 }
    mutating func consume(dx:Double,dy:Double,multiplier:Double)->(Int,Int) {
        guard dx.isFinite,dy.isFinite,multiplier.isFinite,multiplier>0 else { reset();return (0,0) }
        x += dx*multiplier;y += dy*multiplier
        x=min(4096,max(-4096,x));y=min(4096,max(-4096,y))
        let output=(Int(x),Int(y));x -= Double(output.0);y -= Double(output.1)
        return output
    }
}

@MainActor final class TouchpadPreferences: ObservableObject {
    static let shared=TouchpadPreferences()
    private let defaults:UserDefaults
    @Published var value:TouchpadTuning {
        didSet { if let data=try? JSONEncoder().encode(value.normalized) { defaults.set(data,forKey:"henge.touchpad.tuning.v1") } }
    }
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        if let data=defaults.data(forKey:"henge.touchpad.tuning.v1"),let saved=try? JSONDecoder().decode(TouchpadTuning.self,from:data) { value=saved.normalized }
        else { value=TouchpadTuning() }
    }
}
