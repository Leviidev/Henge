import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a running Mac shares with this device: the Shared folder in Files, and the clipboard. The Mac mounts
/// the folder and follows the clipboard through a small helper (host/share.c, tools/henge-agent.m).
@MainActor final class ClipboardStatus: ObservableObject {
    static let shared = ClipboardStatus()
    @Published var busy = false
    @Published var message: String?
}

enum Sharing {
    static let enabledKey = "henge.sharing.enabled"
    private(set) static var enabledForSession = false
    private static var followingClipboard = false
    private static var pasteTask: Task<Void, Never>?
    private static var pasteRevision: UInt64 = 0
    // Dispatch merges guest updates before the main queue drains them. This has
    // no timer and owns no VM memory; delayed events are harmless after leaving.
    private static let clipboardEvents: DispatchSourceUserDataAdd = {
        let events = DispatchSource.makeUserDataAddSource(queue: .main)
        events.setEventHandler { Task { @MainActor in consumeMacClipboard() } }
        events.resume()
        return events
    }()
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    static let setUpCommand = "curl -s http://10.0.2.4/.henge/install | sh"

    /// Before a Mac starts.
    static func prepare() {
        enabledForSession = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        _ = clipboardEvents
        if enabledForSession {
            hv_share_set_clipboard_notify { Sharing.clipboardEvents.add(data: 1) }
        } else {
            hv_share_set_clipboard_notify(nil)
        }
        HengeLog.log("sharing", enabledForSession
                     ? "guest folder and clipboard bridge enabled (local virtual address 10.0.2.4)"
                     : "guest folder and automatic clipboard bridge disabled for this launch")
        guard enabledForSession else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        henge_vm_share(folder.path, socket, Bundle.main.path(forResource: "henge-agent", ofType: "gz"))
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        guard enabledForSession else { return false }
        let seen = henge_share_agent_seen()
        return seen >= 0 && seen < 40
    }

    /// What is copied on the Mac is copied here too. The other way needs the system's paste button: iOS
    /// asks for permission whenever an app reads the clipboard on its own.
    @MainActor static func startFollowingClipboard() {
        setClipboardActive(UIApplication.shared.applicationState == .active)
    }

    @MainActor static func setClipboardActive(_ active: Bool) {
        followingClipboard = active
        if active { consumeMacClipboard() }
        else { cancelPaste() }
    }
    @MainActor static func cancelPaste() {
        pasteRevision &+= 1
        pasteTask?.cancel(); pasteTask = nil
        ClipboardStatus.shared.busy = false
    }
    @MainActor static func stopFollowingClipboard() { setClipboardActive(false) }

    @MainActor private static func consumeMacClipboard() {
        guard followingClipboard, enabledForSession,
              let text = henge_share_take_clipboard() else { return }
        // Opt in to the system's Universal Clipboard rather than local-only
        // storage. Handoff/account/radio availability remains controlled by iOS.
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: String(cString: text)]], options: [.localOnly: false])
        free(text)
    }

    /// Text from this device, pasted at the Mac's cursor. Without the helper it is typed, as far as the keyboard can.
    @MainActor static func paste(_ text: String) {
        guard !ClipboardStatus.shared.busy, UIApplication.shared.applicationState == .active,
              henge_vm_state() == 1 else { return }
        guard !text.utf8.contains(0) else {
            ClipboardStatus.shared.message = "This text contains a null character and cannot be shared safely."
            return
        }
        let generation = henge_vm_generation()
        let status = ClipboardStatus.shared
        pasteRevision &+= 1
        let revision = pasteRevision
        status.busy = true; status.message = nil
        pasteTask = Task { @MainActor in
            defer { if pasteRevision == revision { status.busy = false; pasteTask = nil } }
            let current = { !Task.isCancelled && UIApplication.shared.applicationState == .active &&
                henge_vm_generation() == generation && henge_vm_state() == 1 }
            if helperRunning && henge_share_clipboard_ready() != 0 {
                let seq = henge_share_publish_clipboard(text)
                guard seq != 0 else { status.message = "The text is too large or there is not enough memory to send it."; return }
                switch await ClipboardDelivery.wait(isCurrent: current, isDelivered: { henge_share_clipboard_delivered(seq) != 0 }) {
                case .delivered:
                    guard current() else { return }
                    Keys.chord(Keys.command, "v")
                case .timedOut:
                    status.message = "The Mac has not confirmed the clipboard yet. No paste shortcut was sent. Try again once the Mac responds."
                case .interrupted: break
                }
            } else {
                guard text.allSatisfy({ Keys.canType($0) }) else {
                    status.message = "Set up or update the Mac sharing companion in Details → Sharing to paste this text without losing characters."
                    return
                }
                // An older or absent companion still has a safe US-keyboard fallback.
                for character in text {
                    guard current() else { return }
                    Keys.type(character)
                    do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return }
                }
            }
        }
    }

    /// Types the set up command at the Mac's cursor, and stops there: the person using the Mac presses Return.
    /// Henge can't see what has the keyboard, so it must not submit anything by itself. Opening Terminal for them
    /// through Spotlight was tried: when Spotlight was slow the text went to a web search, and it could as easily
    /// have gone to a chat.
    static func typeSetUpCommand() async {
        await Keys.typeSlowly(setUpCommand)
    }
}
