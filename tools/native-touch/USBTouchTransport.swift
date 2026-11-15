import AppKit
import Foundation
import IOKit

/// Adds the display identity before the touchscreen's event service is matched.
/// This observes ordinary USB hardware; it never creates a virtual HID device.
@MainActor
private final class USBDisplayMapper {
    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var displayUUID = ""
    private(set) var lastError: kern_return_t = KERN_SUCCESS
    private var mappedRegistryID: UInt64 = 0

    static func matching(_ serviceClass: String) -> CFDictionary {
        let matching = IOServiceMatching(serviceClass)! as NSMutableDictionary
        matching["IOPropertyMatch"] = ["VendorID": 0x1209, "ProductID": 0xD007]
        return matching as CFDictionary
    }

    func start(displayUUID: String) throws {
        self.displayUUID = displayUUID
        guard let port = IONotificationPortCreate(kIOMainPortDefault),
              let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw CocoaError(.featureUnsupported)
        }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        let result = IOServiceAddMatchingNotification(port, kIOPublishNotification,
            Self.matching("IOHIDDevice"), { context, iterator in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<USBDisplayMapper>.fromOpaque(context).takeUnretainedValue().bind(iterator)
                }
            }, Unmanaged.passUnretained(self).toOpaque(), &iterator)
        guard result == KERN_SUCCESS else {
            stop()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        bind(iterator)
    }

    private func bind(_ iterator: io_iterator_t) {
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { return }
            lastError = IORegistryEntrySetCFProperty(device, "displayUUID" as CFString, displayUUID as CFString)
            if lastError == KERN_SUCCESS { IORegistryEntryGetRegistryEntryID(device, &mappedRegistryID) }
            IOObjectRelease(device)
        }
    }

    var devicePresent: Bool {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, Self.matching("IOHIDDevice"))
        guard device != 0 else { return false }
        IOObjectRelease(device)
        return true
    }

    var mapped: Bool {
        guard mappedRegistryID != 0 else { return false }
        let device = IOServiceGetMatchingService(kIOMainPortDefault, Self.matching("IOHIDDevice"))
        guard device != 0 else { return false }
        defer { IOObjectRelease(device) }
        var identifier: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(device, &identifier)
        let value = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "displayUUID" as CFString, nil, 0)
        return identifier == mappedRegistryID && value as? String == displayUUID
    }

    func prepareAttachment() { mappedRegistryID = 0; lastError = KERN_SUCCESS }

    func isAssociated() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, Self.matching("IOHIDEventService"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "displayUUID" as CFString, nil,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return value as? String == displayUUID && lastError == KERN_SUCCESS
    }

    func stop() {
        if let port { IONotificationPortDestroy(port) }
        port = nil
        if iterator != 0 { IOObjectRelease(iterator); iterator = 0 }
        mappedRegistryID = 0
    }
}

@MainActor
final class USBTouchTransport {
    private struct State: Decodable {
        let version: Int
        let epoch: UInt32
        let available: Bool
        let connected: Bool
        let hostEncoding: Bool?
        let setupHeartbeat: Bool?
        let failureDetails: Bool?
    }
    private let connection: GuestConnection
    private let epoch: UInt32
    private let mapper = USBDisplayMapper()
    private let base = URL(string: "http://10.0.2.4/.henge/native-touch-usb")!
    private(set) var active = false
    private(set) var hostEncoded = false
    private var setupPhase = 0

    init(connection: GuestConnection, epoch: UInt32) { self.connection = connection; self.epoch = epoch }

    private func setConnected(_ connected: Bool) async throws {
        try await control(connected ? 1 : 0)
    }

    private func control(_ action: Int) async throws {
        var request = URLRequest(url: base)
        request.httpMethod = "PUT"
        request.httpBody = Data("\(epoch) \(action)".utf8)
        let (_, response) = try await connection.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
    }

    private func state() async throws -> State {
        let (data, response) = try await connection.data(from: base)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.version == 1, state.epoch == epoch, state.available else { throw URLError(.badServerResponse) }
        return state
    }

    func start(displayID: CGDirectDisplayID) async throws {
        guard #available(macOS 27.2, *),
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            throw CocoaError(.featureUnsupported)
        }
        let displayUUID = CFUUIDCreateString(nil, uuid) as String
        let capabilities = try await state()
        let reportsProgress = capabilities.setupHeartbeat == true
        setupPhase=1
        let progress: Task<Void, Never>? = reportsProgress ? Task { [connection, epoch] in
            while !Task.isCancelled {
                var request=URLRequest(url:URL(string:"http://10.0.2.4/.henge/native-touch")!)
                request.httpMethod="PUT";request.httpBody=Data("\(epoch) 1 \(self.setupPhase)".utf8)
                _ = try? await connection.data(for:request)
                do { try await Task.sleep(for:.milliseconds(500)) } catch { return }
            }
        } : nil
        defer { progress?.cancel() }
        try mapper.start(displayUUID: displayUUID)
        do {
            // A prior session can leave a service with a cached display identity.
            // Wait for its actual removal before attaching the replacement.
            try await setConnected(false)
            var deadline = ProcessInfo.processInfo.systemUptime + (reportsProgress ? 5 : 4)
            while try await state().connected || mapper.devicePresent {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(25))
            }
            mapper.prepareAttachment()
            setupPhase=2
            try await setConnected(true)
            setupPhase=3
            if reportsProgress { deadline=ProcessInfo.processInfo.systemUptime+5 }
            while !mapper.mapped {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(10))
            }
            // The Report Rate feature query holds event-driver initialization
            // until this acknowledgement, closing the publication/cache race.
            try await control(2)
            setupPhase=4
            if reportsProgress { deadline=ProcessInfo.processInfo.systemUptime+5 }
            while !mapper.isAssociated() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(25))
            }
            // The desktop also has to discover the newly associated service.
            setupPhase=5
            if reportsProgress { deadline=ProcessInfo.processInfo.systemUptime+5 }
            while !NSScreen.screens.contains(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID &&
                    $0.touchCapabilities.contains(.multiTouch)
            }) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(25))
            }
            // New hosts encode UIKit contacts directly into their emulated USB
            // endpoint. The companion still owns display association/liveness.
            if try await state().hostEncoding == true {
                setupPhase=6
                try await control(3)
                hostEncoded = true
            }
            active = true
        } catch {
            if capabilities.failureDetails == true {
                let code=max(-1000000,min(1000000,(error as NSError).code))
                var failure=URLRequest(url:URL(string:"http://10.0.2.4/.henge/native-touch")!)
                failure.httpMethod="PUT";failure.httpBody=Data("\(epoch) 5 \(setupPhase) \(code)".utf8)
                _ = try? await connection.data(for:failure)
            }
            await stop()
            throw error
        }
    }

    func send(_ report: Data) async throws {
        guard active, report.count == 32 else { throw CocoaError(.featureUnsupported) }
        if hostEncoded { return }
        var generation = epoch.littleEndian
        var body = withUnsafeBytes(of: &generation) { Data($0) }
        body.append(report)
        var request = URLRequest(url: base.appendingPathComponent("report"))
        request.httpMethod = "PUT"
        request.httpBody = body
        let (_, response) = try await connection.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
    }

    func stop() async {
        active = false; hostEncoded = false
        try? await setConnected(false)
        mapper.stop()
    }
}
