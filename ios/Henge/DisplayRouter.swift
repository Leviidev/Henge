import SwiftUI
import QuartzCore

/// Owned by SessionView, and shared with its display accessory. Only one layer
/// receives frames; the phone's input views stay alive when the monitor takes over.
@MainActor
final class DisplayRouter: ObservableObject {
    @Published private(set) var isExternal = false

    private var targets = DisplayTargetSelection()
    private var layers: [UUID: CAMetalLayer] = [:]
    private var selected: UUID?
    private var refreshTask: Task<Void, Never>?

    func connect(_ id: UUID, layer: CAMetalLayer, role: DisplayTargetSelection.Role) {
        let replacedSelected = selected == id && layers[id] !== layer
        let previous = selected
        layers[id] = layer
        targets.connect(id, role: role)
        updateTarget()
        if replacedSelected && selected == previous {
            refreshTask?.cancel(); refreshTask = nil
            sendTarget()
        }
    }

    func disconnect(_ id: UUID) {
        targets.disconnect(id)
        updateTarget()
        layers.removeValue(forKey: id)
    }

    /// Re-present the latest frame after layout or a return from the background,
    /// even when macOS is idle and isn't submitting another frame.
    func refresh(_ id: UUID? = nil) {
        guard id == nil || id == selected else { return }
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield() // fold/rotation layout can publish several sizes in one turn
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.sendTarget()
        }
    }

    private func updateTarget() {
        let next = targets.selected
        if next != selected {
            refreshTask?.cancel(); refreshTask = nil
            selected = next
            sendTarget()
        }
        if isExternal != targets.isExternal { isExternal = targets.isExternal }
    }

    private func sendTarget() {
        let layer = selected.flatMap { layers[$0] }
        henge_vm_set_display_layer(layer.map { Unmanaged.passUnretained($0).toOpaque() })
    }
}
