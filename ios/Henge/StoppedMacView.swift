import SwiftUI

/// A stopped guest must not look like a frozen desktop. Restarting the engine
/// still requires a new app launch; keep that limitation explicit here.
struct StoppedMacView: View {
    let outcome: Int32
    let reason: String
    let close: () -> Void

    private var title: String {
        switch outcome {
        case Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue): return "Mac shut down"
        case Int32(HENGE_VM_OUTCOME_RESTART.rawValue): return "Mac requested a restart"
        case Int32(HENGE_VM_OUTCOME_HOST_STOP.rawValue): return "Mac stopped"
        default: return "Mac stopped unexpectedly"
        }
    }

    private var detail: String {
        let next = "Quit Henge and open it again to start this Mac."
        switch outcome {
        case Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue), Int32(HENGE_VM_OUTCOME_HOST_STOP.rawValue): return next
        case Int32(HENGE_VM_OUTCOME_RESTART.rawValue): return "Automatic restart is not available yet. " + next
        default: return "The Mac stopped: \(reason). " + next
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "power").font(.system(size: 30))
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Close", action: close).buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 360)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("stopped-mac")
    }
}
