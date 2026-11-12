import SwiftUI
import UIKit

/// What a running Mac shares with this device: the Shared folder in Files, and the clipboard. The Mac mounts
/// the folder and follows the clipboard through a small helper (host/share.c, tools/henge-agent.m).
enum Sharing {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    static let setUpCommand = "curl -s http://10.0.2.4/.henge/install | sh"
    /// Less background work and drawing in macOS (host/share.c, lighten_script), and back.
    static let lightenCommand = "curl -s http://10.0.2.4/.henge/lighten | sh"
    static let unlightenCommand = "curl -s http://10.0.2.4/.henge/unlighten | sh"

    /// Before a Mac starts.
    static func prepare() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        henge_vm_share(folder.path, socket, Bundle.main.path(forResource: "henge-agent", ofType: "gz"))
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        let seen = henge_share_agent_seen()
        return seen >= 0 && seen < 40
    }

    /// The helper already sends changes in both directions. Remember the change count of our own writes
    /// so that text received from the Mac is not sent straight back to it.
    @MainActor
    static func followClipboard(automatic: Bool) async {
        let board = UIPasteboard.general
        var lastChange: Int?
        while !Task.isCancelled {
            if henge_vm_state() == 1 && UIApplication.shared.applicationState == .active {
                let incoming = henge_share_take_clipboard().map { pointer in
                    defer { free(pointer) }
                    return String(cString: pointer)
                }
                let change = board.changeCount
                if automatic && helperRunning && change != lastChange && board.hasStrings {
                    // Read each change once. If iPadOS denies access, wait for another copy.
                    lastChange = change
                    if let text = board.string {
                        henge_share_set_clipboard(text)
                    } else if let incoming {
                        board.string = incoming
                        lastChange = board.changeCount
                    }
                } else if let incoming {
                    board.string = incoming
                    lastChange = board.changeCount
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// An always-visible alternative to the system paste control.
    @MainActor
    static func pasteFromDevice() {
        guard let text = UIPasteboard.general.string else { return }
        paste(text)
    }

    /// Text from this device, pasted at the Mac's cursor. Without the helper it is typed, as far as the keyboard can.
    static func paste(_ text: String) {
        Task { @MainActor in
            if helperRunning {
                henge_share_set_clipboard(text)
                try? await Task.sleep(nanoseconds: 800_000_000) // for the helper to put it on the Mac's clipboard
                Keys.chord(Keys.command, "v")
            } else {
                await Keys.typeSlowly(text)
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
