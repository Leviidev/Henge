import CoreGraphics

// The Retina size a Mac is given from a panel's pixels and points. UIKit's figures for each device are written out here.
// Run: make test-retina-size

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ got: (width: Int, height: Int), _ want: (Int, Int)) {
    if got.width == want.0 && got.height == want.1 { print("ok   \(name): \(got.width)x\(got.height)") }
    else { failures += 1; print("FAIL \(name): got \(got.width)x\(got.height), want \(want.0)x\(want.1)") }
}
func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

@main
struct RetinaSizeTests {
    static func main() {
        // 12.9" iPad Pro: 2732 x 2048 px, 1366 x 1024 pt, scale 2.
        let ipad13 = size(2048, 2732)
        check("12.9 iPad Pro, whole panel", RetinaSize.panel(nativePixels: ipad13, nativeScale: 2), (2728, 2048))
        check("12.9 iPad Pro, full screen space", RetinaSize.live(points: size(1366, 1024), nativeScale: 2), (2728, 2048))
        // Display Zoom, larger space: about 1590 x 1193 pt. UIScreen.scale stays 2; nativeScale is panel pixels per point.
        let zoomed = size(1590, 1193), zoomedNative = 2048 / zoomed.height
        check("12.9 iPad Pro, Display Zoom, nativeScale", RetinaSize.live(points: zoomed, nativeScale: zoomedNative), (2728, 2048))
        // What the Mac was asked for (#26) when the zoomed space was multiplied by scale (2): more pixels than the panel has.
        check("12.9 iPad Pro, Display Zoom, scale (the bug)", RetinaSize.live(points: size(1588, 1192), nativeScale: 2), (3176, 2384))
        // A window half the screen wide keeps the panel's pixel density.
        check("12.9 iPad Pro, half window", RetinaSize.live(points: size(683, 1024), nativeScale: 2), (1360, 2048))

        // 11" iPad Pro: 1668 x 2420 px, 834 x 1194 pt, scale 2.
        check("11 iPad, whole panel", RetinaSize.panel(nativePixels: size(1668, 2420), nativeScale: 2), (2416, 1664))
        check("11 iPad, full screen space", RetinaSize.live(points: size(1194, 834), nativeScale: 2), (2384, 1664))

        // iPhone Duo unfolded (inner screen): 2853 x 2007 px, 951 x 669 pt, scale 3. Matches the 2848x2000 the device asks for.
        let duoInner = size(2007, 2853)
        check("Duo inner, whole panel", RetinaSize.panel(nativePixels: duoInner, nativeScale: 3), (2848, 2000))
        check("Duo inner, full screen space", RetinaSize.live(points: size(951, 669), nativeScale: 3), (2848, 2000))
        check("Duo inner, portrait space", RetinaSize.live(points: size(669, 951), nativeScale: 3), (2000, 2848))
        check("Duo inner, side strip (84 pt)", RetinaSize.panel(nativePixels: duoInner, nativeScale: 3, strip: 84), (2600, 2000))
        // The Duo's outer screen, as a 640 x 440 pt space at scale 3 (what autopilot's `screen 640 440` asks for).
        check("Duo outer space", RetinaSize.live(points: size(640, 440), nativeScale: 3), (1920, 1320))

        // A regular iPhone (1206 x 2622 px, 402 x 874 pt, scale 3).
        check("iPhone, whole panel", RetinaSize.panel(nativePixels: size(1206, 2622), nativeScale: 3), (2616, 1200))
        check("iPhone, landscape space", RetinaSize.live(points: size(874, 402), nativeScale: 3), (2616, 1200))

        print(failures == 0 ? "retina size: all passed" : "retina size: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
