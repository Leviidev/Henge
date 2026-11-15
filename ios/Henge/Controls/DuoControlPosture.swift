import SwiftUI

/// Reserved-region coordinates are local to this reader. Only an active,
/// horizontal division selects tabletop automatically; manual selection remains
/// useful on compatibility windows or OS versions without posture reporting.
func controllerDivision(_ geometry: GeometryProxy, isDuo: Bool) -> CGRect? {
    guard isDuo else { return nil }
    if #available(iOS 27.1, *) {
        return geometry.reservedRegions(kind:.division,options:.includeInactive).first(where: { $0.isActive })?.frame
    }
    return nil
}
