import Foundation
import QuartzCore

/// What the engine was last told to draw into.
nonisolated(unsafe) var engineLayer: UnsafeMutableRawPointer?
nonisolated(unsafe) var engineCalls = 0

@_cdecl("henge_vm_set_display_layer")
func recordDisplayLayer(_ layer: UnsafeMutableRawPointer?) { engineLayer = layer; engineCalls += 1 }

@main
struct DisplayRouterTests {
    @MainActor static func main() async {
        let phoneLayer = CAMetalLayer(), monitorLayer = CAMetalLayer()
        let phone = UUID(), monitor = UUID()
        let router = DisplayRouter()
        func engineShows(_ layer: CAMetalLayer) -> Bool { engineLayer == Unmanaged.passUnretained(layer).toOpaque() }

        router.connect(phone, layer: phoneLayer, role: .device)
        router.connect(monitor, layer: monitorLayer, role: .external)
        precondition(engineShows(monitorLayer) && router.isExternal)

        // Two monitors (USB-C and AirPlay): the later one shows the Mac. Disconnecting one
        // monitor's surface leaves the other showing it, not the phone.
        let airPlayLayer = CAMetalLayer(), airPlay = UUID()
        router.connect(airPlay, layer: airPlayLayer, role: .external)
        precondition(engineShows(airPlayLayer))
        router.disconnect(airPlay)
        precondition(engineShows(monitorLayer) && router.isExternal)

        // The last monitor going gives the Mac back to the phone, and a late repeat changes nothing.
        router.disconnect(monitor)
        precondition(engineShows(phoneLayer) && !router.isExternal)
        let before = engineCalls
        for _ in 0..<100 { router.refresh(phone) }
        precondition(engineCalls == before)
        for _ in 0..<1000 { if engineCalls != before { break }; await Task.yield() }
        precondition(engineCalls == before + 1 && engineShows(phoneLayer))
        router.refresh(phone)
        router.connect(monitor, layer: monitorLayer, role: .external)
        let switched = engineCalls
        for _ in 0..<10 { await Task.yield() }
        precondition(engineCalls == switched && engineShows(monitorLayer))
        router.disconnect(monitor)
        precondition(engineShows(phoneLayer) && !router.isExternal)
        let replacement = CAMetalLayer()
        let beforeReplacement = engineCalls
        router.connect(phone, layer: replacement, role: .device)
        precondition(engineShows(replacement) && engineCalls == beforeReplacement + 1)
        router.connect(phone, layer: replacement, role: .device)
        precondition(engineCalls == beforeReplacement + 1)
        router.disconnect(phone)
        precondition(engineLayer == nil)
        let newLayer=CAMetalLayer()
        router.connect(phone,layer:newLayer,role:.device)
        precondition(engineShows(newLayer))
        print("Display router: all checks passed")
    }
}
