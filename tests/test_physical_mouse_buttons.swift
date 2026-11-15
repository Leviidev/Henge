import Foundation

@main
struct PhysicalMouseButtonTests {
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }

    static func main() {
        // The upstream default is unchanged; compatibility is opt-in.
        var standard = PhysicalMouseButtons(swapsRightAndMiddle: false)
        for button in [Int32(0), 1, 2] {
            check(standard.event(button, pressed: true) == button, "standard press must not change")
            check(standard.event(button, pressed: false) == button, "standard release must not change")
        }
        check(standard.held.isEmpty, "standard mode must release every button")

        var swapped = PhysicalMouseButtons(swapsRightAndMiddle: true)
        check(swapped.event(0, pressed: true) == 0, "left press must remain left")
        check(swapped.held == [0], "left drag must stay held")
        check(swapped.event(0, pressed: false) == 0, "left release must match left press")
        check(swapped.event(1, pressed: true) == 2, "physical right must map to guest middle")
        check(swapped.event(1, pressed: false) == 2, "right release must match swapped press")
        check(swapped.event(2, pressed: true) == 1, "physical middle must map to guest right")
        check(swapped.event(2, pressed: false) == 1, "middle release must match swapped press")
        check(swapped.held.isEmpty, "mapped releases must not stick")

        // Concurrent presses and disconnect cleanup must release their mapped IDs.
        check(swapped.event(1, pressed: true) == 2, "right hold must use middle")
        check(swapped.event(2, pressed: true) == 1, "middle hold must use right")
        check(swapped.event(1, pressed: true) == nil, "duplicate press must not generate another edge")
        check(swapped.releaseAll() == [1, 2], "cleanup must release mapped buttons")
        check(swapped.releaseAll().isEmpty, "cleanup must be idempotent")
        check(swapped.event(-1, pressed: true) == nil, "negative code must be ignored")
        check(swapped.event(3, pressed: true) == nil, "unsupported code must be ignored")
        check(swapped.held.isEmpty, "invalid input must not stick")

        check(swapped.event(1, pressed: false) == nil, "late up after cleanup must not release another owner")
        var multiple = PhysicalMouseButtons(swapsRightAndMiddle: true)
        check(multiple.event(1, pressed: true, device: "trackpad") == 2, "first owner presses mapped button")
        check(multiple.event(1, pressed: true, device: "mouse") == nil, "second owner does not duplicate down")
        check(multiple.event(1, pressed: false, device: "unknown") == nil, "unmatched release cannot steal hold")
        check(multiple.event(1, pressed: false, device: "trackpad") == nil, "one release preserves other hold")
        check(multiple.held == [2], "remaining owner is still held")
        check(multiple.release(device: "trackpad").isEmpty, "duplicate disconnect does not release mouse")
        check(multiple.release(device: "mouse") == [2], "last owner disconnect emits mapped up")
        check(multiple.event(0, pressed: true, device: "trackpad") == 0, "left hold")
        check(multiple.event(1, pressed: true, device: "mouse") == 2, "independent right hold")
        check(multiple.release(device: "trackpad") == [0] && multiple.held == [2], "disconnect releases only its buttons")
        check(multiple.releaseAll() == [2], "handoff releases remaining physical owners")
        var ownership = LocalPointerOwnership()
        check(ownership.claim(.hardware), "first pointer event claims ownership")
        check(!ownership.claim(.hardware), "motion must not repeat handoff/reset")
        check(ownership.claim(.direct), "touch preempts pointer")
        check(ownership.claim(.hardware), "pointer preempts held touch")
        ownership.reset()
        check(ownership.claim(.hardware), "focus recovery must reestablish pointer ownership")
        check(ownership.claim(.direct), "Pencil claims the display")
        ownership.setDirectContacts(1)
        check(!ownership.permitsHardware(.motion), "incidental trackpad motion cannot cancel an active stroke")
        check(ownership.permitsHardware(.button) && ownership.permitsHardware(.scroll), "deliberate hardware actions can hand off")
        ownership.setDirectContacts(0)
        check(ownership.permitsHardware(.motion), "lifting restores immediate pointer movement")
        ownership.setDirectContacts(1);ownership.reset()
        check(ownership.directContacts == 0 && ownership.permitsHardware(.motion), "focus cleanup cannot retain a stale stroke")
        print("PASS: standard mapping, right/middle swap, left drag, releases and disconnect cleanup")
    }
}
