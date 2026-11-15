import Foundation

/// Compatibility mapping for GameController physical mice/trackpads only.
/// Guest button IDs are 0 = left, 1 = right, 2 = middle; touch controls retain those IDs.
struct PhysicalMouseButtons {
    static let swapKey = "henge.mouse.swapRightAndMiddle"

    /// Captured when the VM session starts, so a held button's release uses the same mapping.
    let swapsRightAndMiddle: Bool
    private var owners: [Int32: Set<AnyHashable>] = [:]
    var held: Set<Int32> { Set(owners.keys) }

    mutating func event(_ physicalButton: Int32, pressed: Bool, device: AnyHashable = 0) -> Int32? {
        guard (0...2).contains(physicalButton) else { return nil }
        let guestButton = swapsRightAndMiddle && physicalButton != 0 ? 3 - physicalButton : physicalButton
        if pressed {
            var sources = owners[guestButton, default: []]
            guard sources.insert(device).inserted else { return nil }
            owners[guestButton] = sources
            guard sources.count == 1 else { return nil }
        } else {
            guard var sources = owners[guestButton], sources.remove(device) != nil else { return nil }
            if !sources.isEmpty { owners[guestButton] = sources; return nil }
            owners.removeValue(forKey: guestButton)
        }
        return guestButton
    }

    /// A disconnected device cannot release a button another mouse still holds.
    mutating func release(device: AnyHashable) -> [Int32] {
        var releases: [Int32] = []
        for button in held.sorted() {
            guard var sources = owners[button], sources.remove(device) != nil else { continue }
            if sources.isEmpty { owners.removeValue(forKey: button); releases.append(button) }
            else { owners[button] = sources }
        }
        return releases
    }

    /// Release all mapped buttons on disconnect or when the VM input session ends.
    mutating func releaseAll() -> [Int32] {
        let releases = held.sorted()
        owners.removeAll()
        return releases
    }
}

/// One local pointer owner; keyboard and remote sources remain independent.
struct LocalPointerOwnership {
    enum Owner: Equatable { case none, hardware, direct }
    enum HardwareIntent: Equatable { case motion, button, scroll }
    private(set) var owner: Owner = .none
    private(set) var directContacts = 0
    mutating func setDirectContacts(_ count: Int) { directContacts = max(0,count) }
    func permitsHardware(_ intent: HardwareIntent) -> Bool {
        // Palm movement on an attached trackpad must not tear a Pencil stroke.
        // An explicit click or scroll still performs a deliberate handoff.
        intent != .motion || directContacts == 0
    }
    mutating func claim(_ next: Owner) -> Bool {
        guard owner != next else { return false }
        owner = next
        return true
    }
    mutating func reset() { owner = .none; directContacts = 0 }
}
