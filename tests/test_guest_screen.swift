import Foundation
import CoreGraphics

@main struct TestGuestScreen {
    static func main() {
        // The reported image: a 1920x1320 guest inside 1280x900 leaves
        // ten pixels above/below. Fit must use the window's actual ratio.
        let viewport = CGSize(width: 1280, height: 900)
        let fitted = GuestScreenSize.fitting(in: viewport)
        precondition(fitted == GuestScreenSize(width: 1920, height: 1350))
        let oldHeight: CGFloat = viewport.width * 1320 / 1920
        precondition((viewport.height - oldHeight) / 2 == 10)
        precondition(abs(viewport.width / fitted.aspect - viewport.height) < 0.0001)
        precondition(GuestScreenSize.fitting(in: CGSize(width: 900, height: 1280)) == fitted)
        // Close ratios no longer snap to the same eight-pixel-height bucket.
        precondition(GuestScreenSize.fitting(in: CGSize(width: 1280, height: 902)).height == 1353)
        for width in stride(from: 1000, through: 2000, by: 13) {
            for height in stride(from: 800, through: width, by: 17) {
                let host = CGSize(width: CGFloat(width), height: CGFloat(height))
                let size = GuestScreenSize.fitting(in: host)
                let requestedHeight = 1920 * CGFloat(height) / CGFloat(width)
                if requestedHeight >= 1080 {
                    precondition(abs(CGFloat(size.height) - requestedHeight) <= 0.5)
                }
                precondition(size.width == 1920 && size.height >= 1080 && size.height <= 1920)
            }
        }
        precondition(GuestScreenSize.fitting(in: CGSize(width: 1000, height: 1000)).height == 1920)
        let wide = GuestScreenSize(width: 1920, height: 1080)
        for invalid in [CGSize(width: 0, height: 0), CGSize(width: -1, height: 1),
                        CGSize(width: CGFloat.nan, height: 10), CGSize(width: CGFloat.infinity, height: 1)] {
            precondition(GuestScreenSize.fitting(in: invalid) == wide)
        }
        precondition(GuestScreenSize.fitting(in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)).height == 1920)
        precondition(GuestScreenSize.fitting(in: CGSize(width: 2556, height: 1179)) == wide)
        let desktop = GuestScreenSize.desktopRetina(in: CGSize(width:1376,height:1032))
        precondition(desktop == GuestScreenSize(width:2560,height:1920))
        precondition(desktop.desktopWorkspace == GuestScreenSize(width:1280,height:960))
        precondition(desktop.desktopWorkspace.width * 2 == desktop.width)
        precondition(desktop.desktopWorkspace.height * 2 == desktop.height)
        // 80% Retina would change the logical workspace; 1x instead preserves it.
        precondition(2048 / 2 != desktop.desktopWorkspace.width)
        // Physical113: a 1181x756.5 window created2560x1640, then a saved
        // restore filled1376x1032 with881.5 guest points and75.25-point bars.
        let window = CGSize(width:1181,height:756.5), panel = CGSize(width:1376,height:1032)
        let windowDesktop = GuestScreenSize.desktopRetina(in: window)
        precondition(windowDesktop == GuestScreenSize(width:2560,height:1640))
        precondition(abs((panel.height-panel.width/windowDesktop.aspect)/2-75.25)<0.001)
        precondition(GuestScreenSize.desktopRetina(in: window,panel:panel)==desktop)
        precondition(GuestScreenSize.desktopRetina(in: .zero,panel:panel)==desktop)
        precondition(GuestScreenSize.desktopRetina(in: window,panel:CGSize(width:1032,height:1376))==desktop)
        precondition(GuestScreenSize.desktopRetina(in: window,panel:.zero)==windowDesktop)
        precondition(GuestScreenSize.fitting(in:window).height==1230) // Fit still follows the window.
        let duo = GuestScreenSize.desktopRetina(in: CGSize(width:951,height:669))
        precondition(duo == GuestScreenSize(width:2560,height:1800))
        precondition(duo.desktopWorkspace == GuestScreenSize(width:1280,height:900))
        precondition(abs(CGFloat(duo.height)-2560*669/951) <= 1)
        precondition(GuestScreenSize.desktopRetina(in: CGSize(width:669,height:951)) == duo)
        precondition(GuestScreenSize.desktopRetina(in: .zero) == desktop)
        print("Desktop Retina: iPad 2560x1920 and Duo aspect/rotation at 1280 logical width passed")
        print("PASS Desktop Retina panel policy: reported Stage Manager/snapshot bars reproduced, stable iPad panel, independent window Fit and Duo geometry preserved")
        // Legacy Fit migration and explicit mode choices, including equal-sized
        // custom profiles, must remain distinguishable after encoding/decoding.
        precondition(GuestScreenSize.usesFit(width: 1920, height: 1320, selected: nil))
        precondition(!GuestScreenSize.usesFit(width: nil, height: nil, selected: nil))
        precondition(!GuestScreenSize.usesFit(width: 1920, height: 1080, selected: nil))
        precondition(!GuestScreenSize.usesFit(width: 1600, height: 1104, selected: nil))
        precondition(!GuestScreenSize.usesFit(width: 1920, height: 1320, selected: false))
        precondition(GuestScreenSize.usesFit(width: 1920, height: 1080, selected: true))
        struct Saved: Codable { var fitScreen: Bool? }
        let old = try! JSONDecoder().decode(Saved.self, from: Data("{}".utf8))
        precondition(old.fitScreen == nil)
        for choice in [true, false] {
            let data = try! JSONEncoder().encode(Saved(fitScreen: choice))
            precondition(try! JSONDecoder().decode(Saved.self, from: data).fitScreen == choice)
        }
        print("guest screen fit: reported slim bars removed mathematically; actual-window/rotation ratios, pixel rounding, wide fallback, legacy migration and explicit mode persistence passed")
    }
}
