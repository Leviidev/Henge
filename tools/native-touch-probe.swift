import Foundation
import CoreHID
import IOKit.hid
import Darwin

/// Diagnostic only: creates a device and sends an all-up report. Never injects a touch.
@main enum NativeTouchAuthorizationProbe {
 static func main() async {
  print("uid=\(getuid()) HID post-event access=\(IOHIDCheckAccess(kIOHIDRequestTypePostEvent).rawValue)")
  guard let device = HIDVirtualDevice(properties: .init(descriptor: NativeTouchDescriptor.descriptor(), vendorID: 0x1209, productID: 0xD006, transport: .virtual, product: "Henge authorization probe", uniqueID: UUID().uuidString)) else {
   print("FAIL: HIDVirtualDevice creation denied"); exit(2)
  }
  await device.activate(delegate: NativeTouchDeviceDelegate())
  do {
   try await device.dispatchInputReport(data: Data([1] + Array(repeating: UInt8(0), count: 31)), timestamp: .now)
   print("PASS: device activated and neutral report dispatched")
  } catch { print("FAIL: \(error)"); exit(3) }
 }
}
