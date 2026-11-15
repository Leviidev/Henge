import AppKit
import Foundation
import Darwin

private func diagnostic(_ message: String) {
    NSLog("Henge touch: %@", message)
}

private struct Command: Decodable {
    let version: Int
    let epoch: UInt32
    let enabled: Bool
    let usb: Bool?
    let contacts: [NativeTouchContact]

    var isValid: Bool {
        version == 1 && epoch != 0 && contacts.count <= 5 && contacts.allSatisfy(\.isValid)
            && Set(contacts.map(\.id)).count == contacts.count
    }
}

/// Runs only inside the guest. No listening socket and no changes to OS security policy.
@main
private enum TouchAgent {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check-launch") {
            print("henge-touch-agent: launch probe reached main; USB connection not tested");return
        }
        // USB publication callbacks need the main CFRunLoop as well as the
        // main actor used by contact handling.
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            application.terminate(nil)
        }
        application.run()
    }

    @MainActor private static func run() async {
        let parent = CommandLine.arguments.dropFirst().first.flatMap(Int32.init) ?? getppid()
        diagnostic("started (parent \(parent))")
        guard CommandLine.arguments.contains("--stdio") else { diagnostic("update the Henge sharing helper"); return }
        // Emulated guests can stall briefly while compiling or servicing I/O.
        let connection = GuestConnection(requestTimeout:.seconds(5))
        await connection.start()
        let url = URL(string: "http://10.0.2.4/.henge/native-touch")!
        let state = AgentState()
        while getppid() == parent && kill(parent, 0) == 0 {
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await connection.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let command = try JSONDecoder().decode(Command.self, from: data)
                guard command.isValid else { throw URLError(.cannotParseResponse) }
                if command.epoch != state.generation {
                    diagnostic("command epoch \(command.epoch), enabled \(command.enabled), USB \(command.usb == true)")
                }
                state.lastCommand = ProcessInfo.processInfo.systemUptime
                if command.epoch != state.generation || !command.enabled {
                    await state.device?.stop(); state.device = nil
                    state.generation = command.epoch; state.failure = 0; state.neutralRequired = true
                }
                guard command.enabled else { continue }
                if state.device == nil && state.failure == 0 {
                    if #available(macOS 27.2, *) {
                        if command.usb != true { state.failure = 5 }
                        else {
                            diagnostic("configuring USB touch")
                            let transport=USBTouchTransport(connection:connection,epoch:command.epoch)
                            let next = SystemNativeTouchDevice(usb: transport)
                            next.onFailure = { reason in diagnostic("report failed: \(reason)"); state.failure = 5 }
                            do {
                                state.display = CGMainDisplayID(); state.bounds = CGDisplayBounds(state.display)
                                try await next.start(displayID: state.display)
                                state.device = next
                                diagnostic("touchscreen ready")
                            } catch { diagnostic("setup failed: \(error)"); await next.stop(); state.failure = 5 }
                        }
                    } else { state.failure = 3 }
                }
                if state.device != nil && (CGMainDisplayID() != state.display || CGDisplayBounds(state.display) != state.bounds ||
                    command.usb != true) {
                    state.failure = 5
                }
                if state.failure != 0 { await state.device?.stop(); state.device = nil }
                else {
                    if command.contacts.isEmpty { state.neutralRequired = false }
                    if !state.neutralRequired { state.device?.enqueue(command.contacts) }
                }
                var report = URLRequest(url: url)
                report.httpMethod = "PUT"
                report.httpBody = Data("\(state.generation) \(state.failure == 0 ? 2 : state.failure)".utf8)
                let (_, acknowledgment) = try await connection.data(for: report)
                guard (acknowledgment as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
                state.lastError = nil
            } catch {
                let failure = error as NSError
                let message = "\(failure.domain) \(failure.code): \(failure.localizedDescription)"
                if state.lastError != message { diagnostic(message); state.lastError = message }
                state.neutralRequired = true
                if state.failure==0, state.device?.hasDirectMapping==true,
                   GuestConnection.canRetainMapping(error:error,elapsed:ProcessInfo.processInfo.systemUptime-state.lastCommand) {
                    // Host-side encoding releases contacts on missed liveness.
                    // Keep a valid mapped endpoint through a bounded pipe stall.
                    state.device?.releaseAll()
                } else {
                    await state.device?.stop(); state.device=nil;state.generation=0
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await state.device?.stop();state.device=nil
        await connection.close()
    }
}

@MainActor
private final class AgentState {
    private var watchdog:Task<Void,Never>?
    var device:SystemNativeTouchDevice? {
        didSet {
            watchdog?.cancel();watchdog=nil
            guard let device, !device.hasDirectMapping else { return }
            // No periodic watchdog when touch is disabled. An active device
            // still releases contacts if a network request stops completing.
            watchdog=Task { @MainActor [weak self,weak device] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
                    guard let self,let device,self.device===device else { return }
                    if ProcessInfo.processInfo.systemUptime-self.lastCommand>0.7 {
                        device.releaseAll();self.neutralRequired=true
                    }
                }
            }
        }
    }
    var generation: UInt32 = 0
    var display: CGDirectDisplayID = 0
    var bounds = CGRect.zero
    var failure = 0
    var neutralRequired = true
    var lastCommand = ProcessInfo.processInfo.systemUptime
    var lastError: String?
}
