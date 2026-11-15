import SwiftUI

struct LocalGamepad: View {
    @ObservedObject private var preferences = GamepadPreferences.shared
    var body: some View {
        GamepadControllerSurface(tuning:preferences.value,send:{ GamepadHub.shared.set($0) },sendPointer:{ GamepadHub.shared.point($0) })
            .frame(height:320*preferences.value.normalized.scale)
            .onDisappear { GamepadHub.shared.set(.off) }
    }
}

struct GamepadSettings: View {
    var mapping: Binding<Bool>? = nil
    @ObservedObject private var hub=GamepadHub.shared
    var body: some View { GamepadSettingsPanel(mapping:mapping ?? $hub.keyboardMapping,allowsNativeProfile:mapping == nil) }
}
