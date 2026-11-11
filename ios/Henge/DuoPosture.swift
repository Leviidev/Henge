import SwiftUI

/// iPhone Duo (iOS 27.1): the hinge and the fold, for the session's laptop layout. With the inner
/// display upright, half folded or open flat, the Mac sits above the fold and the half below it is a
/// keyboard and trackpad, as on a laptop; closed (the cover display) or on its side, the session is
/// laid out as before. Open flat it is the same shape as Henge's own upright layout, whose keyboard
/// button brought up the system keyboard over the trackpad: the deck's keyboard does better there too,
/// and the layout needs no angle, which the phone reported only as 180° when first tried.
///
/// - The hinge comes from `onHingeChange` (`readsDuoHinge()`, on the session), its status and angle.
/// - The fold is the `.division` reserved region, read from the session's GeometryReader: 40 pt across
///   the inner display (a zero-width crease with 20 pt each side), at y 455.5 upright. It is active only
///   while the hinge is partly open; open flat it is there but inactive; the cover display has none.
/// - Before iOS 27.1, on a device without a hinge, and in an app linked against an older SDK (which
///   runs in a compatibility window on the Duo), none of this is there and nothing changes.
struct DuoHinge: Equatable {
    enum Status: Equatable { case unknown, closed, partiallyOpen, fullyOpen }
    var status: Status = .unknown
    /// Degrees, 0 closed to 180 flat; nil when iOS gives none.
    var degrees: Double?
}

enum DuoLaptop {
    static let enabledKey = "henge.duo.laptop"

    /// Whether the session takes the laptop layout: a band across an upright screen (the inner
    /// display's fold, `fold` in the session's space), with the hinge anything but closed.
    static func applies(hinge: DuoHinge, fold: CGRect?, upright: Bool) -> Bool {
        guard upright, let fold, fold.width > fold.height else { return false }
        return hinge.status != .closed
    }
}

/// The fold across the session, in its space (from the device's corner, not the safe area's).
struct DuoFold: Equatable {
    var frame: CGRect
    var isActive: Bool
    /// From the display's size alone: iOS gave no reserved region.
    var inferred = false

    /// The inner display upright, as iOS 27.1 measures it: 669×951 pt,
    /// the crease at half the height and 20 pt each side of it.
    private static let inner = CGSize(width: 669, height: 951)

    /// `full` is the session's size, `insets` where the GeometryReader starts inside it.
    static func read(_ geo: GeometryProxy, full: CGSize, insets: EdgeInsets) -> DuoFold? {
        if #available(iOS 27.1, *),
           let region = geo.reservedRegions(kind: .division, options: .includeInactive).first {
            // A reader's regions are in its own space and not clipped to it.
            return DuoFold(frame: region.frame.offsetBy(dx: insets.leading, dy: insets.top), isActive: region.isActive)
        }
        guard !Device.isPad, abs(full.width - inner.width) < 1, abs(full.height - inner.height) < 1 else { return nil }
        return DuoFold(frame: CGRect(x: 0, y: full.height / 2 - 20, width: full.width, height: 40), isActive: false, inferred: true)
    }
}

extension View {
    /// The hinge into `hinge`; nothing at all before iOS 27.1.
    func readsDuoHinge(_ hinge: Binding<DuoHinge>) -> some View { modifier(DuoHingeReader(hinge: hinge)) }
}

private struct DuoHingeReader: ViewModifier {
    @Binding var hinge: DuoHinge

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                let now = DuoHinge(new)
                guard now != hinge else { return } // it repeats itself while it settles
                // Every 10°, to learn what a real hinge reports.
                if now.status != hinge.status || now.degrees.map({ Int($0 / 10) }) != hinge.degrees.map({ Int($0 / 10) }) {
                    HengeLog.log("duo", "hinge \(now.status)" + (now.degrees.map { String(format: " %.1f°", $0) } ?? ""))
                }
                hinge = now
            }
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private extension DuoHinge {
    init(_ context: DeviceHingeContext) {
        guard let hinge = context.hinge else { self.init(); return }
        let status: Status
        // A struct of statics, not an enum: anything it may say later counts as partly open.
        if hinge.status == .closed { status = .closed }
        else if hinge.status == .fullyOpen { status = .fullyOpen }
        else { status = .partiallyOpen }
        self.init(status: status, degrees: hinge.angle.degrees)
    }
}
