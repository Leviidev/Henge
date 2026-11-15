import Foundation
import CoreGraphics

enum ControllerLayoutChoice: String, CaseIterable, Identifiable {
    case automatic, standard, portrait, tabletop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .standard: return "Wide"
        case .portrait: return "Portrait"
        case .tabletop: return "Tabletop"
        }
    }
}

/// Geometry only: no guest display changes, polling, or inferred hinge angles.
struct ControllerPostureLayout {
    enum Style: Equatable { case standard, portrait, tabletop }
    let style: Style
    let upper: CGRect
    let lower: CGRect
    let fold: CGRect
    init(size: CGSize, choice: ControllerLayoutChoice, isDuo: Bool, division: CGRect?) {
        let bounds=CGRect(origin:.zero,size:size)
        // A vertical division does not form a laptop deck. Ignore off-window or
        // tiny regions; a keyboard/sheet can reduce the available window.
        let candidate=division?.intersection(bounds)
        let usable=candidate.flatMap { r -> CGRect? in
            guard !r.isNull,r.width>size.width*0.7,r.height<r.width,
                  r.minY>=120,size.height-r.maxY>=180 else { return nil }
            return r
        }
        let tabletop=choice == .tabletop || (choice == .automatic && isDuo && usable != nil)
        if tabletop && size.height>=400 && size.width>=300 {
            let gap=usable ?? CGRect(x:0,y:size.height*0.5-16,width:size.width,height:32)
            style = .tabletop;fold=gap
            upper=CGRect(x:0,y:0,width:size.width,height:gap.minY)
            lower=CGRect(x:0,y:gap.maxY,width:size.width,height:size.height-gap.maxY)
        } else {
            style = choice == .portrait || (choice == .automatic && size.height>size.width*1.15) ? .portrait : .standard
            upper = .zero;lower=bounds;fold = .zero
        }
    }
}
