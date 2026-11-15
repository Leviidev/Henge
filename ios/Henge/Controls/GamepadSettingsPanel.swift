import SwiftUI

struct GamepadSettingsPanel: View {
    @Binding var mapping: Bool
    var allowsNativeProfile = true
    @AppStorage("henge.gamepad.profile") private var profile = "generic"
    @ObservedObject private var preferences = GamepadPreferences.shared
    @ObservedObject private var touchpad = TouchpadPreferences.shared
    @ObservedObject private var gyro=GyroSteeringService.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Input") {
                    if allowsNativeProfile {
                        Picker("Native USB profile",selection:$profile) {
                            Text("Generic HID").tag("generic")
                            Text("PS4-compatible (experimental)").tag("ds4")
                        }
                        Text("The native profile applies on the next cold Mac boot. Saved sessions retain their USB device identity. PS4 compatibility needs in-game verification; the A/B/X/Y positions remain the same.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Keyboard / mouse mapping",isOn:$mapping)
                    Text("Native mode sends a USB gamepad. Mapping mode sends WASD, jump and mouse look for games that do not recognise the controller.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Stick response") {
                    adjustment("Movement sensitivity",value:$preferences.value.moveSensitivity,range:0.35...2)
                    adjustment("Look sensitivity",value:$preferences.value.lookSensitivity,range:0.25...3)
                    adjustment("Dead zone",value:$preferences.value.deadZone,range:0...0.35, format:"%.0f%%", multiplier:100)
                    adjustment("Response curve",value:$preferences.value.responseCurve,range:1...2.5, format:"%.2f")
                    Toggle("Invert look Y",isOn:$preferences.value.invertLookY)
                    if mapping {
                        adjustment("Mouse look speed",value:$preferences.value.mouseLookSpeed,range:300...2400, format:"%.0f px/s")
                    }
                }
                Section("Racing · gyro steering") {
                    Toggle("Tilt to steer",isOn:$gyro.enabled).disabled(!gyro.available)
                    adjustment("Full steering angle",value:$gyro.fullLockDegrees,range:15...70, format:"%.0f°")
                    Toggle("Invert steering",isOn:$gyro.inverted)
                    Text(gyro.available ? "Tilt controls horizontal steering. The joystick still controls acceleration/braking and all buttons remain available. Keyboard mapping translates steering to A/D. Recenter while holding the device comfortably." : "This device does not report a motion sensor. Joystick controls remain available.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(gyro.status).font(.caption).foregroundStyle(.secondary)
                }
                Section("Touchpad") {
                    adjustment("Touchpad movement speed",value:$touchpad.value.pointerSpeed,range:0.25...3)
                    adjustment("Touchpad scrolling speed",value:$touchpad.value.scrollSpeed,range:0.25...3)
                    Text("Applies to wireless touchpad, keyboard view and the gamepad touchpad. Saved on this controller device.").font(.footnote).foregroundStyle(.secondary)
                    Button("Reset touchpad sensitivity") { touchpad.value=TouchpadTuning() }
                }
                Section("Overlay") {
                    adjustment("Control size",value:$preferences.value.scale,range:0.8...1.15, format:"%.0f%%", multiplier:100)
                    adjustment("Opacity",value:$preferences.value.opacity,range:0.25...0.85, format:"%.0f%%", multiplier:100)
                    Text("Drag a trigger down to reduce its analog pressure. L3 and R3 press the sticks. Use the three-finger menu to show or hide the overlay.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Reset gamepad tuning") { preferences.value = GamepadTuning() }
            }
            .tint(Desk.accentLight)
            .scrollContentBackground(.hidden).background(Desk.page)
            .navigationTitle("Gamepad settings")
            .onAppear { gyro.setConfigurationVisible(true) }
            .onDisappear { gyro.setConfigurationVisible(false) }
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func adjustment(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.2f×", multiplier: Double = 1) -> some View {
        VStack(alignment:.leading) {
            HStack { Text(name); Spacer(); Text(String(format:format,value.wrappedValue*multiplier)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value:value,in:range).accessibilityLabel(name).accessibilityValue(Text(String(format:format,value.wrappedValue*multiplier)))
        }
    }
}
