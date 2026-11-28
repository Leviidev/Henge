import CoreGraphics

/// The Mac's screen size at Retina density, from what UIKit says about the panel. Pure arithmetic, so the sizes
/// can be checked without a device.
///
/// A point is not a fixed number of pixels. `UIScreen.scale` is the factor the system renders at (2 on an iPad,
/// 3 on an iPhone Duo) and stays put when an iPad is set to a larger-space Display Zoom, while the panel's pixels
/// do not change: `nativeScale` is panel pixels per point and follows the zoom. Pixels from points use `nativeScale`.
enum RetinaSize {
    /// A size macOS is asked for is a multiple of 8, like every size Henge offers.
    private static func floor8(_ v: CGFloat) -> Int { Int(v) / 8 * 8 }

    /// The whole panel on its side, every physical pixel. `strip` is a width in points kept at the right (an
    /// iPhone Duo's side strip for the status bar and controls); it comes off the long side.
    static func panel(nativePixels: CGSize, nativeScale: CGFloat, strip: CGFloat = 0) -> (width: Int, height: Int) {
        let long = max(nativePixels.width, nativePixels.height) - strip * nativeScale
        let short = min(nativePixels.width, nativePixels.height)
        return (floor8(long), floor8(short))
    }

    /// A space of this many points (a window, or the whole screen in the other orientation), in panel pixels.
    static func live(points: CGSize, nativeScale: CGFloat) -> (width: Int, height: Int) {
        (floor8(points.width * nativeScale), floor8(points.height * nativeScale))
    }
}
