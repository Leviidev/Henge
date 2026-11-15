import Foundation
import IOKit

/// Read-only USB publication diagnostic; never creates a HID device or injects input.
@main enum NativeTouchUSBProbe {
    static func main() {
        let matching=IOServiceMatching("IOHIDDevice")! as NSMutableDictionary
        matching["IOPropertyMatch"]=["VendorID":0x1209,"ProductID":0xD007]
        let service=IOServiceGetMatchingService(kIOMainPortDefault,matching)
        guard service != 0 else { print("USB touchscreen not attached; enable native touch with the updated sharing helper.");return }
        defer { IOObjectRelease(service) }
        let uuid=IORegistryEntrySearchCFProperty(service,kIOServicePlane,"displayUUID" as CFString,nil,0)
        print("Henge USB touchscreen present; display association=\(uuid as? String ?? "not mapped yet"). No virtual HID entitlement is used.")
    }
}
