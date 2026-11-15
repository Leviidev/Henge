import Foundation

/// Hardware selection is authoritative in the native topology detector. These
/// are defaults and maintenance decisions, never a claim about core residency.
enum M4Performance {
    static var enabled: Bool { hv_host_is_m4_16gb() != 0 }
    static let statisticsKey = "henge.perf.sessionDiagnostics"
    /// A user-authorized diagnostic IPA starts logging once on first launch.
    /// Later explicit Off choices remain respected; normal releases stay quiet.
    static func prepareDiagnosticBuild(defaults: UserDefaults = .standard,
                                       enabled: Bool = Bundle.main.object(forInfoDictionaryKey:"HengeTestDiagnostics") as? Bool ?? false,
                                       build: String = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown") {
        let key="henge.diagnostics.initialized.\(build)"
        guard enabled,defaults.object(forKey:key)==nil else { return }
        defaults.set(true,forKey:statisticsKey);defaults.set(true,forKey:key)
    }
    static var statisticsEnabled: Bool {
        (UserDefaults.standard.object(forKey: statisticsKey) as? Bool) ?? false
    }
    static var maximumGuestCPUs: Int { enabled ? 8 : 6 }
    /// Used for newly created M4 Macs and the explicitly selected preset only.
    /// Existing saved display choices are never migrated implicitly.
    static func applyRetinaDisplay(to mac: inout VirtualMac) {
        guard enabled else { return }
        mac.desktopLayout = true
        mac.retina = true
        mac.fitScreen = false
        let screen = Device.desktopRetina(in: Device.displayViewport)
        (mac.screenWidth, mac.screenHeight) = (screen.width, screen.height)
    }
    /// Explicit preset only; opening/upgrading Henge never overwrites choices.
    /// Refresh and JIT reservation are independent user choices and stay intact.
    static func applyAutomaticDefaults() {
        guard enabled else { return }
        let defaults = UserDefaults.standard
        // A test build keeps the explicitly enabled diagnostics across presets.
        if Bundle.main.object(forInfoDictionaryKey:"HengeTestDiagnostics") as? Bool != true {
            defaults.set(false,forKey:statisticsKey)
        }
        defaults.set(true,forKey:EngineTuning.fastmemKey)

    }
    static func logProfile() {
        guard enabled else { return }
        HengeLog.log("profile", "M4 iPad16,5 ten-core/16GB: baseline 4 vCPUs, 8GB guest RAM; Retina and requested refresh preserved; diagnostics opt-in; process memory headroom remains dynamic")
    }
}
