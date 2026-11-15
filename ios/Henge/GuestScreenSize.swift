import Foundation

/// Guest pixels for the explicit Fit mode. The containing window, not a cached
/// UIScreen or an old machine's rounded dimensions, determines its shape.
struct GuestScreenSize: Equatable {
    let width: Int
    let height: Int

    var aspect: CGFloat { CGFloat(width) / CGFloat(height) }

    /// A 1x desktop with the same logical workspace as the reference 2x Retina
    /// desktop. MetalFX reconstructs the missing detail; this is not native Retina.
    var desktopWorkspace: Self { Self(width: max(1, width / 2), height: max(1, height / 2)) }

    static func fitting(in viewport: CGSize) -> Self {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return Self(width: 1920, height: 1080)
        }
        let long = max(viewport.width, viewport.height)
        let short = min(viewport.width, viewport.height)
        // Preserve the existing 1920-pixel width and 1080 minimum for wide
        // phones. Height need not be a multiple of eight: row alignment is
        // independent, and rounding it that coarsely creates visible bars.
        return Self(width: 1920, height: max(1080, Int((1920 * (short / long)).rounded())))
    }

    /// Reference desktop composition: 1280 logical points across, rendered at
    /// 2x. An iPad can supply its panel so a temporary Stage Manager window
    /// cannot become the persistent desktop shape. Duo keeps its own viewport.
    /// Explicit alternative to native-panel Retina, not an automatic downgrade.
    static func desktopRetina(in viewport: CGSize, panel: CGSize? = nil) -> Self {
        let area: CGSize
        if let panel, panel.width.isFinite, panel.height.isFinite,
           panel.width > 0, panel.height > 0 { area = panel }
        else { area = viewport }
        guard area.width.isFinite, area.height.isFinite,
              area.width > 0, area.height > 0 else {
            return Self(width: 2560, height: 1920)
        }
        let ratio = min(area.width, area.height) / max(area.width, area.height)
        // Even height keeps the logical 2x backing integral, within one pixel
        // of the requested aspect. Width stays 2560 in folded/inner orientations.
        return Self(width: 2560, height: max(2, Int((1280 * ratio).rounded()) * 2))
    }

    static func usesFit(width: Int?, height: Int?, selected: Bool?) -> Bool {
        if let selected { return selected }
        // Older Fit profiles only stored this size convention. Explicit new
        // choices distinguish Fit from fixed/custom, Retina and 16:9 modes.
        guard width == 1920, let height else { return false }
        return height > 1080 && height <= 1440 && height.isMultiple(of: 8)
    }
}
